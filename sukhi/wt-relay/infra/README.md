# infra — 透過 L4 リレーの土台(WG / sysctl / policy-route)

relay(公開側 x64)と origin(隠す側 ARM, karutte)の**冪等セットアップ**。設計の全体は
`../docs/edge-design.md`。ここが持つのは「土台」で、DNAT(`WT_RELAY` チェーン)は
wt-relay daemon の持ち物(`lib/wt_relay/kernel/iptables.ex`)。

土台はぜんぶ wg-quick の PostUp/PostDown に載せてあるので、**reboot 後は
`wg-quick@wg0` が一式連れてくる**。スクリプトは何度走らせても同じ形に収まる。

## 実 IP・鍵の置き場所

`env.relay` / `env.origin`(gitignore 済み)にだけ書く。docs・example・コミットには
書かない(IP 秘匿が目的なのに履歴に焼くと本末転倒)。

## 使い方

両方の箱に wireguard-tools(`apt install wireguard`)と、この `infra/` を置く。

1. **origin** で `sudo ./setup-origin.sh` — 鍵だけ作って公開鍵を表示して止まる
2. **relay** で `sudo ./setup-relay.sh` — 同じく鍵だけ作って止まる
3. 互いの公開鍵(と relay の `IP:51820`)を相手の `env.*` に書く
4. もう一度 両方で走らせる — wg0 が立ち、土台が入る

外に開くのは **relay の UDP 51820(WG)と UDP 443(クライアント)だけ**(OCI セキュリティ
リストも同様に)。origin は何も開けない(WG は外向きに繋ぐ)。

PostUp を書き換えたときは `wg syncconf` では効かないので
`sudo wg-quick down wg0 && sudo systemctl start wg-quick@wg0`。

## DNAT(手動での素通しテスト)

本来は wt-relay daemon が張る。daemon 抜きで一度通すなら、relay で
(`Iptables.render/1` が出すものと同じ形):

```sh
iptables -t nat -N WT_RELAY 2>/dev/null || true
iptables -t nat -C PREROUTING -j WT_RELAY 2>/dev/null || iptables -t nat -A PREROUTING -j WT_RELAY
iptables-restore -n <<'EOF'
*nat
:WT_RELAY - [0:0]
-A WT_RELAY -p udp --dport 443 -j DNAT --to-destination 10.9.0.2:443
COMMIT
EOF
```

## 検証(edge-design §5-1 の目視)

1. **トンネル**: relay で `ping 10.9.0.2`(origin の keepalive 後)。
2. **素通し**: origin で `socat -v UDP-LISTEN:443,bind=10.9.0.2,fork EXEC:cat`、
   手元から `echo hi | nc -u <relayの公開名> 443` が返る。
3. **実 IP 保存**: origin で `tcpdump -ni wg0 udp port 443` — src が
   クライアントの**実 IP** になっている(10.9.0.1 ではなく)。
4. **無漏洩**(いちばん大事): 上のテスト中、origin で
   `tcpdump -ni <WAN iface> 'udp port 443 or icmp'` が**沈黙**していること。
   origin 発のパケットが WAN 側に一つも出なければ、origin IP は漏れていない。
5. **沈黙の確認**: 外から origin の公開 IP に `nc -u <origin公開IP> 443` — 何も
   返らない(ICMP unreachable も出ない)こと。

MTU: wg0 既定 1420 → UDP payload 1392 で QUIC の最低 1200 は素で満たす。karutte 側で
`maximum_mtu` を絞る話は `../../docs/wt-relay-integration.md` 側。
