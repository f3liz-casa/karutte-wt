# wt-relay

透過 L4（WireGuard）リレーの、親切な制御面 ── 庭師。relay の netfilter を宣言（spec）から
維持し、telemetry を出す。karutte を Cloudflare の裏や使い捨ての最前線に置くための下回り
（[karutte](..) の姉妹プロジェクト、**別ランタイム**）。

## 一番大事な性質 ── データ面はカーネル、制御面は庭師

パケットの転送・観測は **カーネル**（iptables / conntrack / WireGuard）でやる。userspace を
通らない。だからこの daemon（BEAM）が落ちても、`WT_RELAY` チェーンは残り、**relay は流し
続ける**。制御面は「門番」ではなく「庭師」── ルールを整えて観測するだけで、パケットそのものの
通り道には立たない。最前線の 1 コアの箱に常駐 daemon を置いても安全なのは、この分業のおかげ。

## できること

- 宣言（spec）から所有チェーン `WT_RELAY` を **原子適用**（`iptables-restore`）。失敗しても daemon は
  落とさず last-known を保つ。
- 二つのモード: **dnat**（透過 L4 転送・実 IP 保存）/ **observe**（udp/443 を暗号の手前で数える
  L4 テレメトリ ── raw=毎パケット量 / mangle=新規フロー / conntrack）。
- Observer の snapshot を NATS `wt_relay.telemetry` に publish → **sukhi の admin で L4 を一緒に見る**。
- `mix test` 緑（7 passed）＋ **本物の Linux iptables** で実機確認。

「Spectrum のように管理する」＝宣言的な on/off と status/telemetry は自前で持てる。ただし
Spectrum 本体（anycast・グローバル scrubbing）は一箱では再現できない。ここが持てるのは
**「宣言的な L4 管理＋実 IP 保存／観測＋relay/origin 統合 status」**まで、と正直に呼ぶ。

## 走らせ方

```sh
mix test   # dev/test では daemon は起きない（カーネルを触らない）
```

relay の箱（root / CAP_NET_ADMIN・host network）で container 常駐:

```sh
docker build -t wt-relay:v1 .
docker run -d --name wt-relay --restart unless-stopped \
  --network host --cap-add NET_ADMIN \
  -e WT_RELAY_NATS_HOST=10.9.0.2 \      # observe の snapshot を NATS に出すとき
  wt-relay:v1
```

## ドキュメント

- [`docs/design.md`](docs/design.md) — 二つのモード / 構成（モジュール）/ 確かめたこと / 正直なほつれ / 走らせ方の詳細。
- [`docs/edge-design.md`](docs/edge-design.md) — トポロジ・透過 vs SNAT・実 IP 秘匿・flood 対策・QUIC-LB の設計。
- [`infra/README.md`](infra/README.md) — WG / sysctl / policy-route の土台（relay/origin 分岐の冪等スクリプト）。

## このリポジトリについて

設計と骨組みは、Shiro（Claude Opus 4.8）が @nyanrus の横にすわって一緒に組んだもの。
読み違えている所があれば、おしえてください。
