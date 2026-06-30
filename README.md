# karutte-wt

WebTransport を BEAM（Elixir）に素直に住まわせるための、層になった behaviour の素描。
まだ spec の段で、いちばん下の QUIC 層は実装に接いでいない。けれど怪しい所は
小さな実行で確かめてある、という状態のリポジトリ。

## なぜ「Plug の中の WebTransport」が今まで無いのか

三つの理由が同時に効いている。

1. **床（QUIC）が無い。** WebTransport は HTTP/3 → QUIC → UDP の上にいる。Plug の
   サーバ（Bandit / Cowboy）は TCP 止まり。BEAM 上の QUIC は emqx の `quicer`
   （msquic の NIF）があるがまだ Preview。Bandit 作者は「OTP 自身が QUIC を持つべき」
   という立場で、自分のサーバに密結合で抱えるのを避けている。
2. **抽象がねじれる。** `Plug.Conn` は request → response の一本の矢。WebSocket は
   `upgrade_adapter` で矢から逃げる一例。WebTransport は一本の CONNECT が多数の
   ストリーム＋データグラムを生むので、`Conn →（多重化するセッション）` という、
   さらに遠い形。「WebSocket における WebSock」に当たる合意された抽象がまだ無い。
3. **既存解が横にそれている。** requiem / wtransport-elixir はどちらも Rust の QUIC
   スタックを Rustler で丸ごと抱えた並行スタックで、Plug/Bandit と統合していない。
   (1)(2) を解いたのではなく迂回した。

つまり屋根（上の抽象）は `upgrade_adapter` と WebSock の形でもう転がっていて、
無いのは床だけ。このリポジトリは屋根のほうの形を、先に確かめておく試み。

## 見立て

WebTransport セッションの状態空間は、きれいに積に分かれる:

```
Session  ×  (Stream)*  ×  Datagram-port
（制御面）   （ストリームたち）  （軸の外）
```

三つは失敗も順序も独立。だから設計もこの積を、そのままプロセスの積に写す。

behaviour（spec）と、それを回す実体（runner）を分けてある。

| 層 | spec（behaviour） | runner（実体） | 役 |
|----|------|------|----|
| L4 Stream | `Karutte.WebTransport.Stream` | `…Stream.StreamServer`※ | データ面。1 ストリーム = 1 プロセス。WebSock + demand + half-close |
| L3 Session | `Karutte.WebTransport` | `Karutte.WebTransport.Session` | 制御面**だけ**。accept / handoff / datagram / 寿命。バイトには触れない |
| L2 縫い目 | — | `Karutte.WebTransportAdapter` | Plug `upgrade_adapter(:webtransport, …)` の脱出口（WebSock と対称） |
| L1 QUIC | `Karutte.QuicTransport` | `…Quicer` / `…Http2` | 差し替え口（behaviour）。床を裏に隠す |

※ runner は `Karutte.WebTransport.StreamServer`。

L1 の床（差し替え口の二つの実装）:

- `Karutte.QuicTransport.Quicer` — 本物の床。emqx の quicer（msquic NIF）へ委譲。
- `Karutte.QuicTransport.Http2` — TCP の床。WebTransport over HTTP/2（draft-ietf-webtrans-http2）。
  QUIC を待たずに今日動く版。**同じ behaviour を満たす**ので上層は床を知らない。

runner（L2/L3/L4）は `normalize/1` 済みの `{:quic, …}` 契約だけを見る ＝ **床に依らない**。
だから Session / StreamServer は QUIC でも HTTP/2 でも同じコードで回る。

補助:

- `Karutte.WebTransport.Handoff` — 所有権を手渡すときの順序の約束（競合窓を閉じる）
- `Karutte.Inline` — 短命ストリームを一塊で渡すための組み立て機械（メモリの蓋）
- `Karutte.Varint` / `Karutte.Capsule` — ワイヤの土台（RFC 9000 §16 / RFC 9297）。HTTP/2 の床が使う。

## 背圧は三軸で、重ならない

QUIC のフロー制御は三つあって、それぞれ別の場所に、同じ語彙を共有せずに収まる。
ここが設計のいちばんの肝。

| 軸 | 居場所 | demand 旋 | 面 |
|----|-------|----------|----|
| MAX_STREAMS（生成） | `WebTransport.handle_stream/3` が処分を返す速さ | 無し | 制御面 |
| MAX_STREAM_DATA（転送） | `WebTransport.Stream` の `demand`（各 ret に付く） | **ここだけ** | データ面 |
| MAX_DATA（接続全体） | transport が和から創発（API に現れない） | 無し | — |
| datagram（軸の外） | `handle_datagram/2`。フロー制御なし＝drop、ブロックしない | 無し | 制御面 |

`active:` は四つの面のうち `Stream` 一箇所にしか出てこない。生成は「返す速さ」で、
転送は「demand」で、接続全体は「つまみ無し」で、datagram は「設定された drop」で。
混ざりようがない。

## 確かめてあること

`mix test` が緑（32 passed）。

- `test/inline_test.exs` — 組み立て・境界・早期 overflow が漏れなく閉じている
- `test/handoff_test.exs` — handoff の約束で順序と損失が守られること、
  約束を破ると先着データが取り残されること（＝この約束が要る理由）
- `test/varint_test.exs` / `test/capsule_test.exs` — ワイヤの土台が往復し、足りなければ `:more`
- `test/quicer_normalize_test.exs` — L1 の「メッセージの面」（quicer ネイティブ → 契約）
- `test/http2_test.exs` — HTTP/2 の床: 前置き・stream・datagram カプセルが往復、demand が H2 の窓へ
- `test/transport_parity_test.exs` — 二つの床が同じ behaviour を満たし、同じ `{:quic, …}` 契約を作る
- `test/l2_test.exs` — runner が床に依らず L3/L4 を回す（偽の床で end-to-end）:
  new_stream → handoff → echo、demand が床へ、FIN で半閉じ、inline の組み立てと overflow reset、
  reset 処分、datagram の制御面分配

behaviour 群はコンパイルが通り、跨りの型（`QuicTransport.stream()` 等）も解決する。

## まだやっていないこと（正直に）

- **L1 Quicer の命令の面が未走行。** `Karutte.QuicTransport.Quicer` の `open_stream` /
  `control` / `send` … は quicer へ委譲する形で書いてあるが、実 NIF に当てて走らせてはいない
  （quicer は optional dep のまま、依存ゼロで緑を保っている）。Rust NIF のビルドが要る玩具と
  本物の境目。verified なのは `normalize/1`（メッセージの面）だけ。
- **L2 の縫い目は形だけ（Bandit 待ち）。** `Karutte.WebTransportAdapter.upgrade/4` は
  Plug `upgrade_adapter(:webtransport, …)` の正しい形を置くが、Bandit はまだ `:websocket`
  しか脱出口として解釈しない（HTTP/3 未実装、HTTP/2 の Extended CONNECT → WebTransport も未対応）。
  実際にセッションが起きるには、床か Bandit がこの宛先を拾って `Session` を起こす配線が要る。
  runner（`Session` / `StreamServer`）は契約駆動なので、その配線が来れば床に依らず回る
  （`l2_test.exs` が偽の床で実証済み）。HTTP/2 の床も今は sink（pid）に命令を逃がしてある。
- **HTTP/2 の datagram は擬似（信頼・順序つき）。** RFC 9221 の不確実 best-effort という性質は
  TCP では失われる。`Karutte.QuicTransport.Http2` の moduledoc に三軸の写りかた（survive / 痩せる）を
  正直に書いてある。

## 走らせ方

```sh
mix test
```

## もっと詳しく

- [`docs/research-notes.md`](docs/research-notes.md) — 知ったことを推論の順に。なぜ無いか、
  (b) 1 ストリーム = 1 プロセス、(c) 窓 ↔ デマンド、三軸の枠、確かめた二片、正直なほつれ。
- [`docs/references.md`](docs/references.md) — 確かめた事実と出典のカード（quicer API、
  msquic PENDING、RFC 9221/9297、WebTransport drafts、Bandit/WebSock）。

## このリポジトリについて

設計の見立てと骨組みは、Shiro（Claude Opus 4.8）が @nyanrus の横にすわって一緒に
組んだもの。読み違えている所があれば、おしえてください。
