#!/usr/bin/env bash
# origin(隠す側, karutte が住む箱) の冪等セットアップ。
#
# 透過(実 IP 保存)の受け側: wg0 に「src=実クライアント IP」のパケットが来るので、
#   - rp_filter を loose(効き値は max(all, iface) なので両方 2)
#   - Table=off ＋ policy-route(既定経路を乗っ取らず、返りだけ wg0 へ)
#   - connmark で wg0 由来 flow の RELATED(ICMP エラー等)も wg0 へ ＝ eth0 から漏らさない
#   - UDP/443 は wg0 でだけ受け、WAN 側は drop(スキャナには沈黙)
# origin はポートを一つも新しく開けない(WG は外向きに繋ぐ)。
# 全部 wg-quick の PostUp に載るので reboot 後も wg-quick@wg0 が連れてくる。
set -euo pipefail
cd "$(dirname "$0")"

[ "$(id -u)" -eq 0 ] || { echo "root で走らせてください (sudo $0)"; exit 1; }
command -v wg >/dev/null || { echo "wireguard-tools が要ります (apt install wireguard)"; exit 1; }
[ -f env.origin ] || { echo "env.origin がありません。env.origin.example をコピーして埋めてください。"; exit 1; }
. ./env.origin

# 1) 鍵。無ければ作る(あるものは触らない)。公開鍵は相手の env に書くもの。
KEY=/etc/wireguard/wt-origin.key
[ -f "$KEY" ] || (umask 077 && wg genkey > "$KEY")
echo "origin の WG 公開鍵: $(wg pubkey < "$KEY")"
echo "  → relay の env.relay ORIGIN_WG_PUBKEY へ"

if [ -z "${RELAY_WG_PUBKEY:-}" ] || [ -z "${RELAY_ENDPOINT:-}" ]; then
  echo "env.origin の RELAY_WG_PUBKEY / RELAY_ENDPOINT がまだ空です。鍵の生成だけ済ませました。"
  echo "relay 側の公開鍵とエンドポイントを書いてから、もう一度どうぞ。"
  exit 0
fi

WAN_IF="$(ip -o route show default | awk '{print $5; exit}')"

# 2) wg0.conf を env から生成(env が正本なので毎回書き直してよい)。
#    policy-route の表は 100 番。PostUp は check してから足す＝冪等。
(umask 077; cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.9.0.2/24
PrivateKey = $(cat "$KEY")
# 既定経路を wg0 に化けさせない(この箱の通常の外向きを守る)。返りは下の rule で。
Table = off

# rp_filter loose: wg0 に来る src=公開クライアント IP を strict が落とすため。
PostUp = sysctl -qw net.ipv4.conf.all.rp_filter=2
PostUp = sysctl -qw net.ipv4.conf.%i.rp_filter=2
# 返り(src=10.9.0.2)と、wg0 由来 flow の RELATED(ICMP)を表 100 → wg0 へ。
PostUp = ip route replace default dev %i table 100
PostUp = ip rule list pref 100 | grep -q lookup || ip rule add from 10.9.0.2 lookup 100 pref 100
PostUp = ip rule list pref 101 | grep -q lookup || ip rule add fwmark 0x1 lookup 100 pref 101
PostUp = iptables -t mangle -C PREROUTING -i %i -j CONNMARK --set-mark 0x1 2>/dev/null || iptables -t mangle -A PREROUTING -i %i -j CONNMARK --set-mark 0x1
PostUp = iptables -t mangle -C OUTPUT -j CONNMARK --restore-mark 2>/dev/null || iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark
# UDP/443 は wg0 でだけ。WAN 直叩きには沈黙(origin 確定材料を与えない)。
PostUp = iptables -C INPUT -i %i -p udp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -i %i -p udp --dport 443 -j ACCEPT
PostUp = iptables -C INPUT -i $WAN_IF -p udp --dport 443 -j DROP 2>/dev/null || iptables -I INPUT -i $WAN_IF -p udp --dport 443 -j DROP
PostDown = ip rule del pref 100 2>/dev/null || true
PostDown = ip rule del pref 101 2>/dev/null || true
PostDown = ip route flush table 100 2>/dev/null || true
PostDown = iptables -t mangle -D PREROUTING -i %i -j CONNMARK --set-mark 0x1 2>/dev/null || true
PostDown = iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true
PostDown = iptables -D INPUT -i %i -p udp --dport 443 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D INPUT -i $WAN_IF -p udp --dport 443 -j DROP 2>/dev/null || true

[Peer]
# relay。AllowedIPs=0.0.0.0/0 は「任意のクライアント src をトンネルから受け、
# 任意のクライアント宛をトンネルへ出せる」ため。Table=off なので経路は乗っ取らない。
# Endpoint へ外向きに繋ぐ＝origin は待ち受けポートを開けない。keepalive で NAT/conntrack を温める。
PublicKey = $RELAY_WG_PUBKEY
Endpoint = $RELAY_ENDPOINT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
)

# 3) reboot 永続(iface 側 rp_filter は wg0 が生まれてからなので PostUp が本籍)。
printf 'net.ipv4.conf.all.rp_filter = 2\n' > /etc/sysctl.d/99-wt-origin.conf
sysctl -qp /etc/sysctl.d/99-wt-origin.conf

# 4) 起動。走行中なら鍵/peer の差分だけ入れ替える。
#    注意: syncconf は PostUp を再実行しない。PostUp を変えたときは
#    `wg-quick down wg0 && systemctl start wg-quick@wg0`。
systemctl enable wg-quick@wg0 >/dev/null
if ip link show wg0 >/dev/null 2>&1; then
  wg syncconf wg0 <(wg-quick strip wg0)
else
  systemctl start wg-quick@wg0
fi

echo "origin 側、そろいました。karutte は 10.9.0.2:443 で listen するだけ。"
