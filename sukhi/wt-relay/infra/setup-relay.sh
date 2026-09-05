#!/usr/bin/env bash
# relay(公開側) の冪等セットアップ。
#
# ここで整えるのは「土台」だけ: WG の待ち受け・ip_forward・FORWARD の通り道。
# DNAT(WT_RELAY チェーン)はここでは張らない —— それは wt-relay daemon の持ち物
# (lib/wt_relay/kernel/iptables.ex)。土台は wg-quick の PostUp に載せるので、
# reboot 後も wg-quick@wg0 が全部連れてくる。何度走らせても同じ形に収まる。
set -euo pipefail
cd "$(dirname "$0")"

[ "$(id -u)" -eq 0 ] || { echo "root で走らせてください (sudo $0)"; exit 1; }
command -v wg >/dev/null || { echo "wireguard-tools が要ります (apt install wireguard)"; exit 1; }
[ -f env.relay ] || { echo "env.relay がありません。env.relay.example をコピーして埋めてください。"; exit 1; }
. ./env.relay
WG_PORT="${WG_PORT:-51820}"

# 1) 鍵。無ければ作る(あるものは触らない)。公開鍵は相手の env に書くもの。
KEY=/etc/wireguard/wt-relay.key
[ -f "$KEY" ] || (umask 077 && wg genkey > "$KEY")
echo "relay の WG 公開鍵: $(wg pubkey < "$KEY")"
echo "  → origin の env.origin RELAY_WG_PUBKEY へ"

if [ -z "${ORIGIN_WG_PUBKEY:-}" ]; then
  echo "env.relay の ORIGIN_WG_PUBKEY がまだ空です。鍵の生成だけ済ませました。"
  echo "origin 側の公開鍵を書いてから、もう一度どうぞ。"
  exit 0
fi

WAN_IF="$(ip -o route show default | awk '{print $5; exit}')"

# 2) wg0.conf を env から生成(env が正本なので毎回書き直してよい)。
#    PostUp は check してから足す＝冪等。PostDown は鏡写しに消す。
(umask 077; cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.9.0.1/24
ListenPort = $WG_PORT
PrivateKey = $(cat "$KEY")

# データ面はカーネル: 転送を開き、WG の入口と DNAT 後の flow の通り道を通す。
# 443 の INPUT は不要(DNAT が PREROUTING で先に効いて FORWARD になる)。
PostUp = sysctl -qw net.ipv4.ip_forward=1
PostUp = iptables -C INPUT -i $WAN_IF -p udp --dport $WG_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -i $WAN_IF -p udp --dport $WG_PORT -j ACCEPT
PostUp = iptables -C FORWARD -o %i -d 10.9.0.2 -p udp -j ACCEPT 2>/dev/null || iptables -I FORWARD -o %i -d 10.9.0.2 -p udp -j ACCEPT
PostUp = iptables -C FORWARD -i %i -s 10.9.0.2 -p udp -j ACCEPT 2>/dev/null || iptables -I FORWARD -i %i -s 10.9.0.2 -p udp -j ACCEPT
PostDown = iptables -D INPUT -i $WAN_IF -p udp --dport $WG_PORT -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o %i -d 10.9.0.2 -p udp -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i %i -s 10.9.0.2 -p udp -j ACCEPT 2>/dev/null || true

[Peer]
# origin。トンネルの中で origin が名乗るのは 10.9.0.2 だけ。
PublicKey = $ORIGIN_WG_PUBKEY
AllowedIPs = 10.9.0.2/32
EOF
)

# 3) reboot 永続(ip_forward は PostUp にもあるが、こちらが本籍)。
printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-wt-relay.conf
sysctl -qp /etc/sysctl.d/99-wt-relay.conf

# 4) 起動。走行中なら鍵/peer の差分だけ入れ替える。
#    注意: syncconf は PostUp を再実行しない。PostUp を変えたときは
#    `wg-quick down wg0 && systemctl start wg-quick@wg0`。
systemctl enable wg-quick@wg0 >/dev/null
if ip link show wg0 >/dev/null 2>&1; then
  wg syncconf wg0 <(wg-quick strip wg0)
else
  systemctl start wg-quick@wg0
fi

echo "relay 側、そろいました。DNAT は wt-relay daemon(または README の手動手順)で。"
