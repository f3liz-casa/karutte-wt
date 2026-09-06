#!/bin/sh
# 一度だけ、箱で(sudo が要る)。certbot の更新後に heya を restart するように。
# いままでの hook は karutte だけを restart していた。両方書いておく(戻したときも効くように)。
#
#   ssh $BOX
#   sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-karutte.sh <<'HOOK'
#   #!/bin/sh
#   docker restart heya >/dev/null 2>&1 || true
#   docker restart karutte >/dev/null 2>&1 || true
#   HOOK
set -eu
BOX=${BOX:-deploy@138.2.62.89}
ssh "$BOX" 'sudo -n tee /etc/letsencrypt/renewal-hooks/deploy/reload-karutte.sh >/dev/null <<HOOK
#!/bin/sh
docker restart heya >/dev/null 2>&1 || true
docker restart karutte >/dev/null 2>&1 || true
HOOK
sudo -n cat /etc/letsencrypt/renewal-hooks/deploy/reload-karutte.sh'
