# wt-relay — 設計とリファレンス

透過 L4 リレー／L4 テレメトリの「庭師」の中身。トポロジと秘匿・flood 対策の設計は
[`edge-design.md`](edge-design.md)、土台（WG / sysctl / policy-route）は
[`../infra/README.md`](../infra/README.md)、front page は [`../README.md`](../README.md)。

## 二つのモード（route の `mode`）

route は `mode` で役が決まる。同じ庭師が、転送も観測もする。

### dnat — 透過 L4 転送（実 IP 保存）

relay の公開ポートに来たものを、**クライアントの src IP を保ったまま** WireGuard の向こうの
origin へ DNAT で渡す:

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
wg-quick PostUp 載せ＝reboot 永続）にある。

### observe — L4 テレメトリ（数えるだけ）

karutte を同じ箱に直載せしたときは、転送せず **udp/443 を暗号の手前で数える**。データ面には
立たない（`-j RETURN` で素通し）。二層で見る:

- **raw PREROUTING**（毎パケット、conntrack より前）＝ ハンドシェイクにならず捨てられた
  spoof も含む生の UDP 洪水量。
- **mangle PREROUTING ＋ conntrack NEW**（フロー初回だけ）＝ 新規接続レート。
  `packets / new_flows` の比が「なりすまし洪水 vs 正規接続」の指標。

Observer は毎 tick の snapshot（raw/mangle の pkts/bytes・conntrack 総数）を NATS の
`wt_relay.telemetry` に publish する（`WT_RELAY_NATS_HOST` が設定されたときだけ接続。未設定なら
観測は NATS 非依存のまま）。sukhi 側がそれを受けて admin（`/admin/system`）で L4 を自分の
ホストメトリクスと一緒に見せる。

## 構成

| module | 役 |
|--------|----|
| `WtRelay.Route` | 一本の宣言。`mode: :dnat`（origin へ転送）/ `:observe`（数えるだけ） |
| `WtRelay.Spec` | 望ましい routes を宣言（アプリ設定）から読む。毎 tick 読み直す＝宣言的 |
| `WtRelay.Reconciler` | tick で spec に収束。原子適用。失敗しても daemon は落ちない |
| `WtRelay.Kernel.Iptables` | 所有チェーン `WT_RELAY` を各テーブルで丸ごと組み直す（`iptables-restore -n` で原子差し替え） |
| `WtRelay.Observer` | カウンタを読んで `[:wt_relay, …]` telemetry を出す。NATS へ snapshot も publish |
| `WtRelay.Kernel.Cmd` | iptables/wg/ip を叩く縫い目（behaviour、テストで差し替え可） |

宣言（`config/config.exs`）:

```elixir
config :wt_relay, :routes, [
  %{name: "karutte-wt", proto: :udp, listen_port: 443, mode: :observe}
]
```

## 確かめてあること

`mix test` が緑（7 passed）。

- `render` が要るテーブルの `WT_RELAY` を flush して埋める／空 spec でも空に保つ（orphan を残さない）
- `apply` が temp ファイル経由で `iptables-restore` を叩き、後片付けする（原子適用）
- observe が raw=毎パケット / mangle=新規フロー（conntrack NEW）を数える／nat は空
- `iptables -nvxL` の出力から route × テーブル別 pkts/bytes を解析（target 非依存）
- 設定の map / `%Route{}` 両方を正規化

さらに **本物の Linux iptables に一度当てて確認済み**（スタブでなく実機、適用後は後始末）:

- `iptables-restore -n` が `render/1` の出力を受理する（書式が本物に通る）
- 2 回 apply しても DNAT ルールは 1 本＝所有チェーンの原子 flush-refill が効く（orphan を残さない）
- ensure_chain → ensure_jump → restore のコマンド列が実 iptables で動く
- 実 `-nvxL` 出力が `parse_counters/1` の期待書式と一致
- observe の実測: udp/443 に数発 → raw／mangle のカウンタが動き、nat は空、jump は三表に各 1

※ まだ検証していないのは**パケット転送そのもの**（dnat モードの WG＋`infra/` 透過ルーティング＋
karutte が要る、別の段）。単体では「netfilter を宣言的に正しく維持する」までが実機で確認できた範囲。
※ 既知: iptables は `-p udp` を `-p udp -m udp` に正規化して保存する。reconciler は render 同士を
比べるので現状無関係だが、将来カーネル実状態との drift 検知を足すならこの正規化を吸う必要がある。

## まだやっていないこと（正直に）

- **origin role の daemon 化**（`Table=off`＋policy-route＋rp_filter は `infra/` のシェルが持つ。
  Elixir で宣言的に reconcile するのは後）。
- **wg peer 管理**（`wg set`）。WG は `infra/` の wg-quick .conf で立てる前提。
- **wg の telemetry・実 IP 保存の健全性サンプル**（conntrack 数は observe で出るようになった）。
- **rollback-on-unhealthy**（適用後に転送が落ちたら last-known-good に戻す）。
- **PromEx 配線**（sukhi admin へは NATS 経由で出るようになった。PromEx で一枚にまとめるのは後）。
- **`preserve_ip: false` の SNAT**（今は preserve_ip=true 前提で SNAT を足さないだけ）。
- **dnat モードの `infra/` を実機で通す**（スクリプトは書けたが、透過転送そのものは未実行。素通し＋
  実 IP 保存＋無漏洩 tcpdump の目視は `infra/README.md` の手順で）。

## 走らせ方

```sh
mix test            # dev/test では daemon は起きない（カーネルを触らない）
```

relay の箱（要 root / CAP_NET_ADMIN・host network）で常駐させる。container で:

```sh
docker build -t wt-relay:v1 .          # Dockerfile は multi-stage release（runtime は jammy）
docker run -d --name wt-relay --restart unless-stopped \
  --network host --cap-add NET_ADMIN \
  -e WT_RELAY_NATS_HOST=10.9.0.2 \      # observe の snapshot を NATS に出すとき
  wt-relay:v1
```

`--network host` でホストの netns を共有し、`NET_ADMIN` で netfilter を触る。データ面は
kernel に居るので、この container を止めても `WT_RELAY` チェーンは残り転送は続く。

※ Docker 29 はネイティブ nftables を使うので、ホストの `iptables -t nat -S WT_RELAY` は
「incompatible」と言う。実体は `sudo nft list table ip nat` で見える（チェーンもルールも
そこに在る）。daemon は container 内の iptables-nft で読み書きするので影響なし。
