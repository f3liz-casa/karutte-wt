# wt-relay

透過 L4（WireGuard）リレーの、親切な制御面。まだ最小の骨組みで、けれど怪しい所は
小さな実行で確かめてある、という状態のリポジトリ。

relay の公開ポートに来た UDP/TCP を、**クライアントの src IP を保ったまま（透過）**
WireGuard の向こうの origin へ DNAT で渡す。その「望ましい状態」を宣言（spec）から
reconcile し、telemetry を出す。CloudFlare Spectrum を一箱で真似るための下回り
（[karutte](..) の WebTransport を CF の裏の origin に通す前段。同じ repo の姉妹プロジェクト）。

## 一番大事な性質 ── データ面はカーネル、制御面は庭師

パケットの転送は **カーネル**（iptables DNAT / conntrack / WireGuard）でやる。userspace を
通らない。だからこの daemon（BEAM）が落ちても、`WT_RELAY` チェーンは残り、**relay は
流し続ける**。制御面は「門番」ではなく「庭師」── ルールを整えて観測するだけで、パケット
そのものの通り道には立たない。最前線の 1 コアの箱に常駐 daemon を置いても安全なのは、
この分業のおかげ。

「Spectrum のように管理する」＝宣言的な on/off と status/telemetry は自前で持てる。ただし
Spectrum の本体（anycast・グローバル scrubbing）は一箱では再現できない。ここが持てるのは
**「宣言的な L4 リレー管理＋実 IP 保存＋relay/origin 統合 status」**まで、と正直に呼ぶ。

## 透過（実 IP 保存）の並び

```
Client(C) ──UDP/443──▶ Relay(x64, <relay-public-ip>) ──WireGuard──▶ Origin(ARM, karutte)
                        wg0=10.9.0.1              wg0=10.9.0.2:443 で karutte が listen
```

- relay は **dst だけ** DNAT（→ 10.9.0.2:443）。**src は書き換えない**（SNAT を足さない）。
- origin は wg0 で src=実クライアント IP のパケットを受ける（要 rp_filter=loose、`Table=off`＋
  policy-route で返りを wg0 に戻す）。karutte の socket に実 IP が乗る。
- 返りは conntrack が自動で un-DNAT ＝ クライアントは relay の公開 IP から返ってきたと見える。
  origin の IP は WG の裏に隠れる。

WG / rp_filter / policy-route の具体は `infra/` の冪等スクリプト（relay/origin 分岐、
wg-quick PostUp 載せ＝reboot 永続）にある。この repo の Elixir は
**relay 側の netfilter を宣言的に維持する制御面**を担う。

## 構成

| module | 役 |
|--------|----|
| `WtRelay.Spec` | 望ましい routes を宣言（アプリ設定）から読む。毎 tick 読み直す＝宣言的 |
| `WtRelay.Reconciler` | tick で spec に収束。原子適用。失敗しても daemon は落ちない |
| `WtRelay.Kernel.Iptables` | 所有チェーン `WT_RELAY` を丸ごと組み直す（`iptables-restore -n` で原子差し替え） |
| `WtRelay.Observer` | カウンタを読んで `[:wt_relay, …]` telemetry を出す |
| `WtRelay.Kernel.Cmd` | iptables/wg/ip を叩く縫い目（behaviour、テストで差し替え可） |

宣言（`config/config.exs`）:

```elixir
config :wt_relay, :routes, [
  %{name: "karutte-wt", proto: :udp, listen_port: 443, origin: "10.9.0.2:443", preserve_ip: true}
]
```

## 確かめてあること

`mix test` が緑。

- `render` が `WT_RELAY` を flush して DNAT で埋める／空 spec でも空に保つ（orphan を残さない）
- `apply` が temp ファイル経由で `iptables-restore` を叩き、後片付けする（原子適用）
- `iptables -nvxL` の出力から route 別 pkts/bytes を解析
- 設定の map / `%Route{}` 両方を正規化

さらに **本物の Linux iptables に一度当てて確認済み**（スタブでなく実機、適用後は後始末）:

- `iptables-restore -n` が `render/1` の出力を受理する（書式が本物に通る）
- 2 回 apply しても DNAT ルールは 1 本＝所有チェーンの原子 flush-refill が効く（orphan を残さない）
- ensure_chain → ensure_jump → restore のコマンド列が実 iptables で動く
- 実 `-nvxL` 出力が `parse_counters/1` の期待書式と一致

※ まだ検証していないのは**パケット転送そのもの**（WG＋`infra/` の透過ルーティング＋karutte が要る、
別の段）。wt-relay 単体は「DNAT チェーンを宣言的に正しく維持する」までが実機で確認できた範囲。
※ 既知: iptables は `-p udp` を `-p udp -m udp` に正規化して保存する。reconciler は render 同士を
比べるので現状無関係だが、将来カーネル実状態との drift 検知を足すならこの正規化を吸う必要がある。

## まだやっていないこと（正直に）

- **origin role の daemon 化**（`Table=off`＋policy-route＋rp_filter は `infra/` のシェルが持つ。
  Elixir で宣言的に reconcile するのは後）。
- **wg peer 管理**（`wg set`）。WG は `infra/` の wg-quick .conf で立てる前提。
- **conntrack / wg の telemetry**、実 IP 保存の健全性サンプル。
- **rollback-on-unhealthy**（適用後に転送が落ちたら last-known-good に戻す）。
- **PromEx 配線**（origin=karutte の telemetry と一枚に束ねる段で）。
- **`preserve_ip: false` の SNAT**（今は preserve_ip=true 前提で SNAT を足さないだけ）。
- **`infra/` を実機で通す**（スクリプトは書けたが未実行。素通し＋実 IP 保存＋無漏洩 tcpdump の
  目視は `infra/README.md` の手順で、karutte を繋ぐ段に）。

## 走らせ方

```sh
mix test            # dev/test では daemon は起きない（カーネルを触らない）
```

relay の箱（要 root / CAP_NET_ADMIN・host network）で常駐させる。container で:

```sh
docker build -t wt-relay:v0 .          # Dockerfile は multi-stage release（runtime は jammy）
docker run -d --name wt-relay --restart unless-stopped \
  --network host --cap-add NET_ADMIN wt-relay:v0
```

`--network host` でホストの netns を共有し、`NET_ADMIN` で netfilter を触る。データ面は
kernel に居るので、この container を止めても `WT_RELAY` チェーンは残り転送は続く。

※ Docker 29 はネイティブ nftables を使うので、ホストの `iptables -t nat -S WT_RELAY` は
「incompatible」と言う。実体は `sudo nft list table ip nat` で見える（チェーンもルールも
そこに在る）。daemon は container 内の iptables-nft で読み書きするので影響なし。

## このリポジトリについて

設計と骨組みは、Shiro（Claude Opus 4.8）が @nyanrus の横にすわって一緒に組んだもの。
読み違えている所があれば、おしえてください。
