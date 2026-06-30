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
| L1 QUIC | `Karutte.QuicTransport` | `…Http3` / `…Quicer` / `…Http2` | 差し替え口（behaviour）。床を裏に隠す |

※ runner は `Karutte.WebTransport.StreamServer`。

L1 の床（差し替え口の三つの実装）:

- `Karutte.QuicTransport.Http3` — **本物の床（動く）**。WebTransport over HTTP/3。quicer（QUIC）の
  上に cowlib（H3/QPACK）を載せ、`Karutte.Http3.Server` / `Karutte.Http3.Connection` が
  リスナと接続を回す。ブラウザが実際に使う道。
- `Karutte.QuicTransport.Quicer` — 素の QUIC への薄い委譲＋メッセージ正規化（Http3 の部品）。
- `Karutte.QuicTransport.Http2` — TCP の床。WebTransport over HTTP/2（draft-ietf-webtrans-http2）。
  ブラウザ非対応のフォールバック（Elixir↔Elixir 用）。

runner（L2/L3/L4）は `normalize/1` 済みの `{:quic, …}` 契約だけを見る ＝ **床に依らない**。
だから Session / StreamServer は HTTP/3 でも HTTP/2 でも同じコードで回る。

HTTP/3 サーバ機構（`Karutte.Http3.*`）:

- `Karutte.Http3.Server` — quicer リスナ + acceptor。
- `Karutte.Http3.Connection` — 接続ごとの GenServer。quicer の唯一の所有者として cow_http3_machine で
  H3/QPACK/Extended CONNECT を捌き、WT ストリーム/datagram を runner へ振る。
- `Karutte.Http3.Cert` — 自己署名 ECDSA 証明書＋`serverCertificateHashes` 用の SHA-256。
- `Karutte.Http3.Echo` — いちばん素朴な WebTransport ハンドラの例（受けたものを返す）。

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

`mix test` が緑（41 passed）。**実 QUIC で end-to-end が通っている**:

- `test/http3_loopback_test.exs` — 最小 Elixir クライアント↔ H3 WebTransport サーバを実 quicer で繋ぐ:
  - connect → H3 SETTINGS → Extended CONNECT(webtransport) → 200 → WT 双方向ストリーム echo → datagram echo
  - 一つの H3 接続に**独立した二つの WT セッション**（session_id で振り分け）
  - **CLOSE_WEBTRANSPORT_SESSION capsule** でそのセッションだけ畳まれ、runner の terminate が走る

そして **本物のブラウザ（Chrome 149）でも確認済み**: 自己署名証明書を `serverCertificateHashes`
でピン留めして `new WebTransport("https://localhost:4433/")`、双方向ストリーム echo（"hi"→"hi"）と
datagram echo（"ping"→"ping"）が通った。サーバは一連のやり取りを通して落ちない。

以下は純粋断片の verify:

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

- **軽い実装の割り切り。** 一接続で複数 WT セッション・CLOSE capsule は対応した。一方で
  DRAIN capsule は記録のみ（新規ストリーム抑制は未）、CONNECT 以外のリクエストは 404、
  GOAWAY・寿命まわりは最小限。"prod で軽く" の段（重い本番化はこの先）。
- **L2 の Plug 縫い目（`Karutte.WebTransportAdapter`）は別経路。** これは Bandit に WebTransport を
  載せる将来用の形で、いまの HTTP/3 サーバ（`Karutte.Http3.*`）は Bandit を介さず quicer に直に立つ。
- **HTTP/2 の床はブラウザ非対応のフォールバック。** datagram は擬似（信頼・順序つき）になる。

## 走らせ方

```sh
mix test
```

### ブラウザから繋ぐ（WebTransport over HTTP/3）

自己署名証明書を作って Echo サーバを起こす:

```elixir
{:ok, cert} = Karutte.Http3.Cert.generate("priv/cert")
{:ok, _pid} = Karutte.Http3.Server.start_link(
  port: 4433, certfile: cert.certfile, keyfile: cert.keyfile,
  handler: Karutte.Http3.Echo)
IO.puts("sha-256(base64): " <> cert.sha256_b64)
```

ブラウザ（Chrome）から、その SHA-256 をピン留めして繋ぐ:

```js
const hash = Uint8Array.from(atob("<上で出た base64>"), c => c.charCodeAt(0));
const wt = new WebTransport("https://localhost:4433/", {
  serverCertificateHashes: [{ algorithm: "sha-256", value: hash }],
});
await wt.ready;
const s = await wt.createBidirectionalStream();
const w = s.writable.getWriter(); await w.write(new TextEncoder().encode("hi"));
// echo が s.readable から返る
```

自己署名で繋げる条件は ECDSA・有効期間 14 日以内（`Cert.generate` がそれを満たす）。
ちゃんとした CA 証明書を使うなら `certfile` / `keyfile` を直接 `Server.start_link` に渡せばよい。

## もっと詳しく

- [`docs/research-notes.md`](docs/research-notes.md) — 知ったことを推論の順に。なぜ無いか、
  (b) 1 ストリーム = 1 プロセス、(c) 窓 ↔ デマンド、三軸の枠、確かめた二片、正直なほつれ。
- [`docs/references.md`](docs/references.md) — 確かめた事実と出典のカード（quicer API、
  msquic PENDING、RFC 9221/9297、WebTransport drafts、Bandit/WebSock）。

## このリポジトリについて

設計の見立てと骨組みは、Shiro（Claude Opus 4.8）が @nyanrus の横にすわって一緒に
組んだもの。読み違えている所があれば、おしえてください。
