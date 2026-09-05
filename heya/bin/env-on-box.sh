#!/bin/sh
# 箱の ~/heya.env を作る(一度だけ)。いまの karutte の env(橋の鍵・NATS・証明書)を引き継ぎ、
# OAuth の鍵は Mac の ~/.secrets/.env.heya から、HEYA_SECRET は箱で新しく作る。値は画面に出さない。
set -eu
BOX=${BOX:?BOX=user@host を渡してください(箱の住所は repo に置かない)}
scp -q "$HOME/.secrets/.env.heya" "$BOX:~/heya.env.oauth"
ssh "$BOX" '
  set -e
  {
    docker inspect karutte --format "{{range .Config.Env}}{{println .}}{{end}}" | grep -E "^(WT_TICKET_PUBKEY|NATS_HOST|NATS_PORT)="
    cat ~/heya.env.oauth
    echo "HEYA_SECRET=$(head -c 48 /dev/urandom | base64 | tr -d "\n=/+")"
    echo "HEYA_CERTFILE=/le/live/webtransport.f3liz.casa/fullchain.pem"
    echo "HEYA_KEYFILE=/le/live/webtransport.f3liz.casa/privkey.pem"
    echo "HEYA_WT_PORT=443"
    echo "HEYA_HTTP_PORT=4000"
    echo "HEYA_SUKHI=https://sukhi.f3liz.casa"
  } > ~/heya.env
  rm ~/heya.env.oauth; chmod 600 ~/heya.env
  echo "~/heya.env: $(wc -l < ~/heya.env) 行"; cut -d= -f1 ~/heya.env | tr "\n" " "; echo
'
