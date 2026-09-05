#!/bin/sh
# heya を x64 の箱(karutte が居るところ)に出す。
#   1. heya と karutte(core + sukhi の lib/mix)を箱の ~/heya-build に運ぶ
#   2. 箱で karutte:v1 の上に heya:vN を焼く(msquic は焼き直さない。ログに "Compiling quicer" が出たら止める)
#   3. karutte を止めて heya を上げる(UDP 443=WT、TCP 443=ページ)。戻すときは docker start karutte
# 秘密は箱の ~/heya.env(0600)。無ければ bin/env-on-box.sh で作る。
set -eu
BOX=${BOX:-deploy@138.2.62.89}
TAG=${TAG:-v$(date +%Y%m%d%H%M)}
HERE=$(cd "$(dirname "$0")/.." && pwd)
KARUTTE=${KARUTTE:-$HERE/../core}
SUKHI=${SUKHI:-$HERE/../sukhi}

echo "== 運ぶ ($TAG)"
ssh "$BOX" 'mkdir -p ~/heya-build/heya ~/heya-build/karutte ~/heya-build/sukhi'
rsync -az --delete "$HERE/lib" "$HERE/priv" "$HERE/mix.exs" "$HERE/Dockerfile" "$BOX:~/heya-build/heya/"
rsync -az --delete "$KARUTTE/lib" "$KARUTTE/mix.exs" "$KARUTTE/mix.lock" "$BOX:~/heya-build/karutte/"
rsync -az --delete "$SUKHI/lib" "$SUKHI/mix.exs" "$SUKHI/mix.lock" "$BOX:~/heya-build/sukhi/"

echo "== 焼く"
ssh "$BOX" "cd ~/heya-build && docker build -f heya/Dockerfile -t heya:$TAG . 2>&1 | tee ~/heya-build.log | grep -E 'Compiling|Generated|ERROR|error' | tail -20"
if ssh "$BOX" "grep -q 'Compiling quicer' ~/heya-build.log"; then
  echo "quicer を焼き直そうとしている。deps の版がずれている。止める。"; exit 1
fi

echo "== 上げる"
ssh "$BOX" "
  docker rm -f heya 2>/dev/null || true
  docker stop karutte 2>/dev/null || true
  docker run -d --name heya --restart unless-stopped \
    --env-file ~/heya.env \
    -v /etc/letsencrypt:/le:ro \
    -p 443:4433/udp -p 443:4000/tcp \
    heya:$TAG
  sleep 8; docker logs --tail 12 heya
"
echo "== 手元から"
curl -s -o /dev/null -w 'TCP 443: %{http_code}\n' --max-time 10 https://webtransport.f3liz.casa/ || echo 'TCP 443 に届かない(OCI の security list か iptables)'
