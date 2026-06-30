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

| 層 | モジュール | 役 |
|----|-----------|----|
| L4 Stream | `Karutte.WebTransport.Stream` | データ面。1 ストリーム = 1 プロセス。WebSock + demand + half-close |
| L3 Session | `Karutte.WebTransport` | 制御面**だけ**。accept / handoff / datagram / 寿命。バイトには触れない |
| L1 QUIC | `Karutte.QuicTransport` | 差し替え口。quicer / Rust NIF / 将来の純 Elixir を裏に隠す |

補助:

- `Karutte.WebTransport.Handoff` — 所有権を手渡すときの順序の約束（競合窓を閉じる）
- `Karutte.Inline` — 短命ストリームを一塊で渡すための組み立て機械（メモリの蓋）

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

`mix test` が緑（7 passed）。

- `test/inline_test.exs` — 組み立て・境界・早期 overflow が漏れなく閉じている
- `test/handoff_test.exs` — handoff の約束で順序と損失が守られること、
  約束を破ると先着データが取り残されること（＝この約束が要る理由）

behaviour 群はコンパイルが通り、跨りの型（`QuicTransport.stream()` 等）も解決する。

## まだやっていないこと（正直に）

- **L1 が quicer に未接続。** `Karutte.QuicTransport` の具体実装（`controlling_process/2` /
  `handoff_stream/2` / passive `recv` + `PENDING`）がまだ。ここは Rust NIF のビルドが要る、
  玩具と本物の境目。
- **L2（HTTP/3 Extended CONNECT + Capsule, RFC 9297）と Plug 接続**（`upgrade_adapter`）が
  まだコメントの中。
- **HTTP/2 バインディング**（draft-ietf-webtrans-http2, TCP）を「同じ上層の二実装目」として
  載せる話は構想だけ。これができれば QUIC を待たずに今日動かせる版になる。

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
