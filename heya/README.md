# heya (部屋)

An audio-only room that opens from a Zulip call link. Zulip keeps one "Jitsi server URL" per
realm and its call button just links to `<that URL>/<room>`. So a server that returns a page
at `/<room>` looks like Jitsi to Zulip. No WebRTC. Voice rides on WebTransport datagrams
([karutte-core](../core)). The koe voice agent joins the same way, or over a WebSocket where
QUIC cannot reach.

```
Browser (Chrome/Firefox) ── WT datagram :4433  /<room>       ──┐
koe (Julia, Hayate)      ── WT datagram :4433  /<room>?token= ──┤── Heya.Room   fans out everyone else's voice
koe (fallback)           ── WebSocket  :4000  /koe/<room>     ──┤
Page                     ── Bandit     :4000  /<room>         ──┘
```

One frame shape: `<<from::8, voice::binary>>`. `from = 0` is control (JSON: you / members /
join / leave); 1..250 are participants. Voice is 16 kHz mono in 20 ms frames: raw PCM
(Int16, 640 bytes) by default, or Opus when both ends agree (koe: `KOE_OPUS=1`; the page
still speaks PCM). The server never looks at the bytes and never mixes. Mixing happens at
the receiver. **Your own voice never comes back to you**, so no echo cancellation is needed.

## Modules

- `Heya.Room`: one process per room. Who is here, and fan-out. Re-sends the roster every
  3 s (control rides on datagrams, which can be lost). Drops voice for a member whose mailbox
  is more than a second behind; never drops control.
- `Heya.WT`: the WebTransport door, a `Karutte.WebTransport` handler. `/<room>?name=<name>`,
  admitted when the gate is open or `?token=` matches `HEYA_KOE_TOKEN`.
- `Heya.KoeSocket`: the WebSocket door for koe, `/koe/<room>`, same token.
- `Heya.Tcp`: a plain TCP door on localhost, kept for the box's own use.
- `Heya.Gate`: a room is open only for a window after a sukhi admin opens it. Persisted to
  `state/gate.json` so a redeploy does not close it.
- `Heya.Web` / `Heya.Auth`: the pages (`/` is an introduction, `/<room>` is the room) and
  Mastodon-compatible OAuth against sukhi to find admins. `HEYA_HOST` is the canonical name
  for OAuth callbacks.
- `Heya.Application` routes `/wt…` to `Karutte.Bridge` (sukhi's timeline) and everything else
  to `Heya.WT`, on the same port.

`HEYA_DEBUG=1` logs datagram counts in and out every 3 s, per participant, for chasing dropouts.

## Running

```sh
mix deps.get && mix test
HEYA_KOE_TOKEN=aikotoba mix run --no-halt
# :4000 page, :4433 WT (self-signed 13 days, hash embedded in the page), :7333 TCP
```

Open `http://localhost:4000/asobi`, enter a name, press 入る. koe joins with
`KOE_HEYA=asobi KOE_HEYA_URL=https://127.0.0.1:4433 HEYA_KOE_TOKEN=aikotoba julia --project=. -t 2 koe.jl`.

Production: `HEYA_CERTFILE` / `HEYA_KEYFILE` for a real certificate. The container listens
on `HEYA_WT_LISTEN` (4433) and docker maps UDP 443 to it; `HEYA_WT_PORT` is what the page
tells browsers. UDP 443 has to reach the box directly (Cloudflare Tunnel does not carry
HTTP/3). Set Zulip's "Jitsi server URL" to `https://<host>`. `BOX=user@host bin/deploy.sh`
ships it; the box's address is not kept in the repo. `bin/certbot-hook.sh` restarts heya
after a certificate renewal.

Path dependencies: `../core` and `../sukhi`.

Not yet: a WebSocket fallback for Safari (the koe WebSocket door is not a browser page);
Opus on the page; turn-taking inside the room (answer when named, don't interject in a
conversation between people).
