# karutte-sukhi

[karutte-core](../karutte-core)（BEAM 上の WebTransport サーバ）を、fedi サーバ **sukhi** の
live タイムラインを配る最前線として使うための応用。芯は core に、ここには sukhi の事情だけ。

## この repo の構成

- **ルート** … `Karutte.Ticket`（sukhi が Ed25519 で署名した入場チケットの検証）と
  `Karutte.Bridge`（NATS の feed を 1 feed = 1 uni ストリームで WebTransport へ流すハンドラ）。
  `run.exs` が、`WT_TICKET_PUBKEY` があれば Bridge、無ければ core の echo を上げる。
- **`wt-relay/`** … 透過 L4 リレー／L4 テレメトリの「庭師」（**別ランタイム・別コンテナ**の姉妹
  プロジェクト）。karutte を Cloudflare の裏や使い捨ての最前線に置くときの下回りで、netfilter を
  宣言的に維持しつつ暗号の手前で flood を数える。ランタイムを分けているのは意図的で、
  「観測者は観測対象より長生きすべき」「netfilter 権限を最前線プロセスに渡さない」から。
  設計は [`wt-relay/docs/edge-design.md`](wt-relay/docs/edge-design.md)。

## 使う

```sh
mix test
```

`karutte_wt` は path 依存（`../karutte-core`）。Dockerfile はビルド文脈の外を見られないので、
コンテナで組むときは core を hex か git 依存に切り替える必要がある（まだ）。

## ドキュメント

- [`docs/wt-relay-integration.md`](docs/wt-relay-integration.md) — エッジ経路（透過 L4・実 IP 保存・秘匿・flood）の karutte 側。
- [`wt-relay/`](wt-relay/) — L4 リレー／テレメトリの庭師（別ランタイム）。

## このリポジトリについて

設計の見立てと骨組みは、Shiro（Claude Opus 4.8）が @nyanrus の横にすわって一緒に
組んだもの。読み違えている所があれば、おしえてください。
