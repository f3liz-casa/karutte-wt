# karutte-core

WebTransport を BEAM（Elixir）に素直に住まわせるための、層になった behaviour ＋その実体。
最初は「屋根（上の抽象）だけ先に確かめる素描」だったが、いまは **いちばん下の QUIC 層まで
接いで、本物のブラウザ（Chrome）と WebTransport over HTTP/3 で喋れる**ところまで来ている。
quicer（QUIC）＋ cowlib（H3/QPACK）の上に、WebTransport 固有の部分と runner を載せた。

これは WebTransport サーバの芯だけ。fedi 向けの応用（Ed25519 チケット・NATS 橋・L4 リレー）は
姉妹リポジトリ **karutte-sukhi** に分けてある。

## いま出来ていること

- **実 QUIC で end-to-end**、本物のブラウザ（Chrome 149）で WebTransport over HTTP/3 が通る（`mix test` 69 passed）。
- 1 つの H3 接続に**複数の WT セッション**、**背圧は三軸で重ならない**、**ストリーム単位のクラッシュ隔離**。
- **server push**（uni/bidi）、**graceful drain**、`authorize/1` の門番、`[:karutte, :http3, …]` telemetry。

なぜこれが今まで無かったか・層モデル・背圧の三軸・検証の全部・正直なほつれは
**[`docs/design.md`](docs/design.md)** に。

## 使う

```sh
mix test
```

### アプリに組み込む

`Karutte.Http3.Server` は監視ツリーひと組で `child_spec/1` を持つので、自分の supervision tree に
そのまま子として挿せる:

```elixir
children = [
  {Karutte.Http3.Server,
   port: 4433, certfile: "priv/cert.pem", keyfile: "priv/key.pem",
   handler: MyApp.WebTransportHandler, max_sessions: 16, acceptors: 4}
]
Supervisor.start_link(children, strategy: :one_for_one)
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

## ドキュメント

- [`docs/design.md`](docs/design.md) — なぜ無いか / 層モデル / 背圧の三軸 / 確かめたこと全部 / 正直なほつれ。
- [`docs/research-notes.md`](docs/research-notes.md) — 知ったことを推論の順に。
- [`docs/references.md`](docs/references.md) — 確かめた事実と出典のカード（quicer API、RFC、drafts）。

## このリポジトリについて

設計の見立てと骨組みは、Shiro（Claude Opus 4.8）が @nyanrus の横にすわって一緒に
組んだもの。読み違えている所があれば、おしえてください。
