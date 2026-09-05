# 研究ノート — 知ったこと

このリポジトリを起こす前後で確かめたことを、推論の順に残す。
事実そのもの（API のかたち、RFC の条文）と出典は `references.md` に分けてある。

## 1. なぜ「Plug の中の WebTransport」が無いのか

「無い」には深さの違う三つの理由があって、全部が同時に効いている。

### 1.1 床（QUIC）が無い

WebTransport は HTTP/3 → QUIC → UDP の上にいる。Plug のサーバ（Bandit / Cowboy）は
いちばん下が TCP（Bandit の土台 Thousand Island は TCP アクセプタ・プール）。
HTTP/3 を作るには QUIC、QUIC には UDP スタックを「ほぼ最初の原理から」積む必要がある。

BEAM 上の QUIC は emqx の `quicer`（msquic を NIF で包んだもの）があるが、まだ Preview。
Bandit 作者 Mat Trudel の立場は「アーキテクチャ的には **OTP 自身が QUIC を持つべき**で、
Bandit はその上に HTTP/3 を書きたい」。つまり彼は自分のサーバの下に QUIC を
密結合で抱え込むことを *避けたがっている*。床がまだ乾いていない。

### 1.2 抽象がねじれる（ここが本質）

`Plug.Conn` は **request → response** という一本の矢をモデルにする。
Plug パイプライン全体が「`Conn → Conn` で、最後に終わる関数」。

WebSocket はすでにこの形からはみ出していて、`upgrade_adapter` という *脱出口* で扱われる。
`call/2` の終わりに request が矢から逃げ、別のプロトコル・ハンドラがソケットを引き継ぐ。
Conn は *握手の運び手* として使われたあと捨てられる。

WebTransport はそこからさらに遠い。一本の CONNECT ストリームが、たくさんのストリーム
＋データグラムを *生む*。形は `Conn → Conn` でも、WebSocket のような
`Conn →（ひとつの継続セッション）` でもなく、**`Conn →（ストリームを多重化するセッション）`**。
入れ子・ファンアウトがある。

だから *仮に明日 QUIC が降ってきても*、まだ「WebSocket における WebSock」に当たる
**合意された抽象が無い**。WebSock がきれいなのは、WebSocket が「順序づき全二重メッセージ列
ひとつ」だから `handle_in/handle_info` に素直に落ちるから。WebTransport は
「それの *集合* ＋ データグラム」なので、多重化の物語なしには一枚の callback モジュールに
落ちない。

### 1.3 既存解が横にそれている

実在する二つ — requiem（xflag）と wtransport-elixir — はどちらも、Rustler で Rust の
QUIC スタック（quiche フォーク / wtransport crate）を丸ごと抱える *並行スタック* で、
独自 callback（`handle_stream` / `handle_dgram`）を持ち、Plug/Bandit とは一切統合していない。
どちらも experimental。つまり既存解は 1.1 と 1.2 を *解いた* のではなく *迂回した*。
だから「Plug の中の WebTransport」は今もって空席。

**結論**: 屋根（上の抽象）は `upgrade_adapter` と WebSock の形でもう転がっていて、
噛み合っている。無いのは床だけ。このリポジトリは屋根のほうの形を先に確かめる試み。

## 2. (b) 1 ストリーム = 1 プロセス — 深掘りで「制御面 / データ面」に割れる

最初は「セッション = 台帳（registry）」と考えていたが、quicer の現実の配達経路を見ると、
もっと鋭い不変条件が見えた。

quicer で peer が新しいストリームを開くと、イベントは **まず connection owner に届く**。
owner はそれを `handoff_stream/2` で別プロセスに *手渡す*。手渡しには `wait_for_handoff`
→ `{handoff_done, Stream, PostHandoff}` という順序保証つきのプロトコルがあり、
accept と handoff の隙間に来たデータも取りこぼさない。済んだあとは、
ストリームのバイトは **NIF から直接そのプロセスへ** 流れる。

ここに割れ目が見える:

| | 通るもの | 担当 |
|---|---|---|
| **制御面 (control plane)** | new_stream / accept / handoff / 寿命 / datagram 分配 | セッション（接続 owner）1 個 |
| **データ面 (data plane)** | 各ストリームのバイト列 | ストリームごとのプロセス |

なので「session = registry」は、こう直すのが正確だった:

> **セッションは制御面 *だけ*。accept・handoff・datagram・寿命を捌き、
> ストリームのバイトには絶対に触れない。**

この「絶対に触れない」が HoL ブロッキングを遠ざける *不変条件*。もしセッションを
データ面にも置いたら、全ストリームが一本のメールボックスに集まって、QUIC が消したはずの
HoL が復活する。quicer の handoff 機構はまさにこの不変条件を守るためにある。

### 2.1 なぜ BEAM では「1 接続 1 プロセスで全ストリームを持つ」が悪いか

- 1 プロセス = 1 リダクション予算 = 1 メールボックス。ストリーム A のハンドラが重いと、
  同じプロセスのストリーム B が待つ（スケジューラ層の HoL）。
- ストリーム別にメールボックスを漁る selective receive は O(メールボックス長)。
- crash 分離が消える。一本の壊れたハンドラが全ストリームを道連れにする。

逆に「1 ストリーム = 1 プロセス」には型理論的な裏もある。**QUIC ストリームハンドルは
NIF リソースで、controlling process がちょうど一つ**（`:gen_tcp` と同じ）。これは
*affine（線形）リソースを唯一の所有者が持つ* 形そのもの。Rust の wtransport が
ストリームを所有権で表すのと同じことを、BEAM では「プロセス = リソース所有＋直列化の単位」
で表す。だから 1stream=1process は趣味ではなく **リソースモデルが要求している**。

### 2.2 短命ストリームのコスト → accept-disposition

handoff は 1 ストリームあたり数メッセージの往復＋プロセス spawn。spawn 自体は安い（~1µs）が、
「1 RPC = 1 bidi ストリーム」のような高頻度・短命ワークロードだと往復レイテンシが乗る。

なので **accept 時に処分（disposition）を選べる** のが完成形:

```
{:handler, mod, arg}   # 長命: プロセスを立てて所有させる
{:inline, max}         # 短命: FIN まで ≤max でバッファし一塊で渡す（太った datagram 扱い）
{:reset, code}         # 要らない
```

長命はプロセス、短命はインライン。コストをストリームの寿命に合わせる。
（`Karutte.WebTransport.disposition` 型がこれ。）

## 3. (c) QUIC 窓 ↔ デマンド背圧 — 願望ではなく、quicer に既に実装されていた

passive モードでは、ストリームデータはバッファされ、アプリが `quicer:recv/2` で引く。
引かれていないとき NIF は `is_recv_pending` を立て、**msquic に `QUIC_STATUS_PENDING` を
返して receive callback を止める**。止まれば MAX_STREAM_DATA の窓が伸びず、送り手がブロックされる。
つまり:

> **アプリが消費する量 ＝ フロー制御クレジット**

の鎖が、`{active, N}`（N 枚届いたら止まる）／ passive `recv`（引いた分だけ）どちらでも、
下では同じ `PENDING` に落ちて成立している。(c) は実在した。

### 3.1 WebSock の補正

WebSocket は常に active（TCP が下で透過的にフロー制御するので、アプリにデマンド旋が無い）。
WebTransport のストリーム別フロー制御は **アプリから見える** し、見えないと slow handler の
メールボックスが無限に膨らむ。だから **ストリーム behaviour = WebSock ＋ デマンド旋**。
「WebSock をそのまま」はここだけ崩れる（`Karutte.WebTransport.Stream` の `demand` 型）。

## 4. 見つけた枠 — 背圧は「三軸」で、信頼クラスごとに違う

QUIC のフロー制御は実は三つあって、それぞれ別の BEAM 機構にきれいに割り当たる。

| QUIC のフロー制御 | 意味 | 対応する BEAM 機構 | 面 |
|---|---|---|---|
| **MAX_STREAMS** | ストリームを *いくつ* 開けるか | accept callback のスループット | 制御面 |
| **MAX_STREAM_DATA** | 1 ストリームに *どれだけ* | ストリームプロセスのデマンド（`active,N`/`recv`） | データ面 |
| **MAX_DATA** | 接続全体で *どれだけ* | msquic が transport 層で自動管理（和から創発） | — |

そして **datagram はこの三軸の外**。RFC 9221 で datagram は **フロー制御を持たない＝
過負荷なら捨てる**。だから datagram をストリームと同じデマンド機構に通すのは *間違い*
（無限バッファか接続停止になる）。datagram の正しい背圧は「有界キュー → drop、決してブロックしない」。

> **背圧の戦略は、チャネルの信頼クラスの関数。**
> 信頼順序ストリーム → デマンド駆動（無損失・ブロックする）。
> 不確実 datagram → 有界 drop（有損失・絶対ブロックしない）。

美しいのは、**セッション（制御面）が accept 点であること自体が、ストリーム *生成* の
背圧（MAX_STREAMS）になっている** こと。セッションは「データ面に乗らない」一方で
「生成の背圧弁」という役目をちょうど担う。三軸が三つの分離した場所に、重ならずに収まる。

`active:` は四つの面のうち `Stream` 一箇所にしか出てこない。生成は「返す速さ」で、
転送は「demand」で、接続全体は「つまみ無し」で、datagram は「設定された drop」で。
混ざりようがない。（型の上での確認は README の表と各 behaviour を。）

### 4.1 GenStage という鏡

GenStage のデマンド模型は QUIC フロー制御と *文字どおり* 同じ。ストリームを producer・
デマンド = MAX_STREAM_DATA クレジットとして書ける。理論の鏡としては正しいが、単純な
consumer には重い。実用形は `{active, N}` で、同じデマンド思想を機械なしで得るほうが素直。

## 5. 確かめた二片

玩具の transport で、肝心の順序とバッファだけを露わにして実行で確認した。
（いまは `Karutte.WebTransport.Handoff` / `Karutte.Inline` として本体に置き、
`test/` が両側から押さえている。）

### 5.1 handoff の競合窓

```
素朴(待たない/吸わない):  ["B", "C", "D"]        ← "A" が消える
正しい(handoff_done 待ち): ["A", "B", "C", "D"]   ← 順序が保たれる
```

ストリームのバイトは `new_stream` を受けた瞬間まだ古いオーナーのメールボックスに届きうる。
新オーナーがいきなり live を読むと、隙間の "A" は古いオーナーに残って消える。
`handoff_done` で「先着分を吸い出して渡す／新オーナーは受けるまで live に触れない」という
順序の約束を一つ入れるだけで、無損失・無順序狂いになる。

検証中の事故が、奇しくも *この約束が要る理由そのもの*（見捨てられたデータが residual として
メールボックスに残り後から汚す）を見せてくれた。`control/2` の前後を
「吸い出す → 手渡す → 再生 → active 化」の一直線にすること。

### 5.2 inline の組み立て機械

```
揃う(max10):               {:done, "hello"}
溢れる(max8, FIN 前に超過):  {:overflow, 8}   ← FIN を待たず即 reset
ちょうど max=5 で FIN:       {:done, "hello"} ← 境界は超過でなく許す
1チャンクで超過(max4):       {:overflow, 4}
```

純粋関数 `feed/2` の三枝で「FIN まで貯める／max で打ち切る／境界ちょうどは通す」が漏れなく閉じる。
**溢れは FIN を待たずチャンク到着時点で出る**ので、過大な inline ストリームでメモリが膨らむ前に
reset できる。`:inline` という「制御面に開けた穴」に、メモリ境界という蓋が閉まる。

## 6. 正直なほつれ

- **`:inline` は不変条件への意図的な穴**。短命ストリームを制御面で受ける。L3 が
  「FIN まで ≤max でバッファして組み立て済みの小片だけ渡す」機械を挟むことで、
  per-byte には触れないまま逃がす。上限 `max` がメモリ境界。
- **half-close で `ret` が太った**。`push_fin` / `close_write` / `reset` と、WebSock の
  素朴な `{:push, …}` より枝が増えた。QUIC ストリームが方向ごとに閉じる以上避けられない正直な複雑さ。
- **datagram のメールボックス膨張**。フロー制御が無い以上、NIF→BEAM 境界で *こちらが*
  drop しないと slow なセッションのメールボックスが膨らむ。有界キュー＋drop は必須。
- **handoff の競合窓**。新オーナーは `handoff_done` を受けるまで passive で受け、
  手渡し完了後に active 化する。間違えると最初の数バイトが順序狂いする。

## 7. 次の境目

- **L1 を quicer の実 API に接ぐ**（`controlling_process/2` / `handoff_stream/2` /
  passive `recv` + `PENDING`）。Rust NIF のビルドが要る、玩具と本物の境目。
- **L2（HTTP/3 Extended CONNECT + Capsule, RFC 9297）＋ Plug `upgrade_adapter(:webtransport, …)`**。
- **HTTP/2 バインディング**（draft-ietf-webtrans-http2, TCP）を「同じ上層の二実装目」に。
  これができれば QUIC を待たず今日動く版になる（TCP なので HoL は戻り、datagram は信頼配送で
  擬似化される — 正しいが意味論は痩せるフォールバック）。**この二実装が同じ Session/Stream
  behaviour を共有する**ことが、層を分けたことの本当のごほうび（関手的な性質）。
