# heya(部屋)

Zulip の通話リンクで開く、音だけの部屋。Zulip は「Jitsi サーバの URL」を realm の設定で一つ持っていて、
通話ボタンは `<その URL>/<部屋名>` のリンクを作るだけ。だから `/<部屋名>` でページを返せば、Zulip からは Jitsi に見える。
WebRTC は使わない。声は WebTransport の datagram(`../core` の karutte-core)で、koe は素の TCP で入る。

```
ブラウザ(Chrome/Firefox) ── WT datagram :4433 ──┐
koe(Julia)              ── TCP 127.0.0.1:7333 ──┤── Heya.Room  自分以外の声だけ配る
ページ                   ── Bandit :4000 /<部屋>  ┘
```

枠は一つ: `<<from::8, pcm::binary>>`。from=0 は制御(JSON: you/members/join/leave)、1〜250 は参加者。
pcm は 16kHz mono Int16 LE、20ms(320 サンプル)ずつ。サーバは混ぜない。混ぜるのは受ける側
(ブラウザは AudioWorklet で、koe は `Heya.mix!`)。**自分の声は自分に戻らない**ので、エコー消しが要らない。

```
mix deps.get && mix test          # 4 本
mix run --no-halt                 # :4000 ページ、:4433 WT(自己署名 13 日、hash はページに埋まる)、:7333 koe
```

ブラウザで `http://localhost:4000/asobi` を開いて名前を入れて「入る」。
koe は `KOE_HEYA=asobi julia --project=. -t 2 koe.jl`(部屋では起き番なし、ずっと聞いている、眠らない)。

本番: `HEYA_CERTFILE`/`HEYA_KEYFILE` に本物の証明書、`HEYA_WT_PORT=443`。UDP 443 を箱まで直に通す
(Cloudflare Tunnel は H3 を運ばない)。Zulip の realm 設定「Jitsi server URL」を `https://<host>` に。

まだ: Safari 向けの WebSocket の逃げ道 / Opus(いまは生 PCM 256kbps) / 部屋の中の順番(名前を呼ばれたら答える、人どうしの話に相槌を打たない)。
