# heya (部屋)

An audio-only room that opens from a Zulip call link. Zulip keeps one "Jitsi server URL" per
realm and its call button just links to `<that URL>/<room>`. So a server that returns a page
at `/<room>` looks like Jitsi to Zulip. No WebRTC. Voice rides on WebTransport datagrams
([karutte-core](../core)); the koe voice agent joins over plain TCP.

```
Browser (Chrome/Firefox) ── WT datagram :4433 ──┐
koe (Julia)              ── TCP 127.0.0.1:7333 ──┤── Heya.Room   fans out everyone else's voice
Page                     ── Bandit :4000 /<room> ┘
```

One frame shape: `<<from::8, opus::binary>>`. `from = 0` is control (JSON: you / members /
join / leave); 1..250 are participants. Voice is Opus, 16 kHz mono, one 20 ms packet per
frame, 24 kbps, with DTX in the browser so a silent participant sends almost nothing. The
server never looks at the bytes and never mixes. Mixing happens at the receiver (the browser
decodes with WebCodecs into an AudioWorklet; koe decodes with libopus into `Heya.mix!`).
**Your own voice never comes back to you**, so no echo cancellation is needed.

## Modules

- `Heya.Room`: one process per room. Who is here, and fan-out. Drops voice for a member whose
  mailbox is more than a second behind; never drops control messages.
- `Heya.WT`: the browser's door, a `Karutte.WebTransport` handler. `/<room>?name=<name>`.
- `Heya.Tcp`: koe's door. Length-prefixed frames on localhost.
- `Heya.Gate`: a room is open only for a window after a sukhi admin opens it (ETS; closes on restart).
- `Heya.Web` / `Heya.Auth`: the page, and Mastodon-compatible OAuth against sukhi to find admins.
- `Heya.Application` routes `/wt…` to `Karutte.Bridge` (sukhi's timeline) and everything else
  to `Heya.WT`, on the same port.

## Running

```sh
mix deps.get && mix test
mix run --no-halt      # :4000 page, :4433 WT (self-signed 13 days, hash embedded in the page), :7333 koe
```

Open `http://localhost:4000/asobi`, enter a name, press 入る. koe joins with
`KOE_HEYA=asobi julia --project=. -t 2 koe.jl` (in a room it never sleeps and needs no wake word).

Production: `HEYA_CERTFILE` / `HEYA_KEYFILE` for a real certificate, `HEYA_WT_PORT=443`.
UDP 443 has to reach the box directly (Cloudflare Tunnel does not carry HTTP/3). Set Zulip's
"Jitsi server URL" to `https://<host>`. `BOX=user@host bin/deploy.sh` ships it; the box's
address is not kept in the repo.

Path dependencies: `../core` and `../sukhi`.

Not yet: a WebSocket fallback for Safari; turn-taking inside the room (answer when named,
don't interject in a conversation between people).
