# What can be built on this

A memo. karutte-core gives Elixir three things browsers could not get from the BEAM before,
and each one opens a different kind of application.

## The three things

1. **Datagrams to a browser.** Unreliable, unordered, no head-of-line blocking, ~20 ms end to
   end. WebSocket cannot do this; WebRTC can, but drags a whole media stack with it.
2. **Many independent streams on one connection**, each with its own flow control, each its
   own BEAM process. A slow consumer of one stream does not stall the others. A crash in one
   stream handler is contained to that stream.
3. **Server-initiated streams and path routing** on a single port, so one server can host
   several unrelated protocols and push without being asked.

Built already: a live-timeline push (sukhi, one stream per feed) and a voice room (heya,
datagrams, one process per participant). Both are small. That is the point.

## Things that fit well

**Real-time state with a tolerance for loss** (datagrams)
- Multiplayer game state: positions, inputs, at tick rate. The server is a fan-out of small
  packets; stale ones are dropped, never queued. heya's Room is already this shape.
- Live cursors and presence in a shared document. Cursor moves are datagrams; edits are a
  reliable stream. Two axes, one connection.
- Sensor and telemetry feeds from devices or from koe: audio levels, positions, readings.
- Remote control of physical things where the newest command matters and old ones do not.

**Fan-out of independent feeds** (streams, one per topic)
- Anything shaped like "subscribe to N topics": chat rooms, notifications, dashboards, log
  tailing. One stream per topic means a busy topic cannot delay a quiet one. The Bridge is
  the template; swap NATS for PubSub, Phoenix.PubSub, or a GenStage.
- Server-sent events with backpressure. SSE has none; a stream's demand is real backpressure.

**Bulk transfer with fairness** (streams, demand-driven)
- File upload and download where each file is a stream and the client's demand throttles the
  server per file. Large payloads are already tested (multi-frame round trips).
- Bidirectional streaming RPC: request on the way out, response chunks on the way back, with
  half-close per direction. gRPC-like, without HTTP/2 framing.

**Media** (datagrams + WebCodecs)
- Screen or camera sharing between a few people: VideoEncoder frames as datagrams, keyframes
  on a reliable stream. heya's audio path generalizes; the server still never looks at bytes.
- A "poor person's MoQ" relay: one uplink stream in, N downlinks out, at the application layer.

**Interactive tools**
- A remote terminal or REPL: input stream, output stream, resize as datagrams. One process
  per session, crash-isolated.
- A LiveView-style UI over WebTransport. Diffs on a stream, interactions on datagrams. Not
  something Phoenix does yet; the seam (`Karutte.WebTransportAdapter`) is sketched but the
  Bandit side is missing.

**With koe (the voice agent)**
- koe is already in the room over TCP. Give it a datagram port and it can be in the room from
  another box, or several koe on several boxes in one room.
- Wake-word and ASR results as a control stream alongside voice, so the browser sees what koe
  heard as it hears it.
- Duplex translation: voice in, translated voice out, per participant, each on its own stream.

## What it is not (yet)

- **Not for Safari.** Safari's WebTransport support is new and untested here. A WebSocket
  fallback would need a separate server path.
- **Not behind Cloudflare.** Cloudflare does not proxy WebTransport. UDP must reach the box;
  that is what `wt-relay` is for.
- **Not a web server.** Anything but CONNECT gets a 404. Serve pages from Bandit next to it,
  as heya does.
- **Not integrated with Plug or Phoenix.** The `upgrade_adapter` seam is a sketch. Doing it
  for real means either Bandit learning HTTP/3 or a WebTransport-to-WebSock shim, and that is a
  larger project than anything in this repo.
- **Not load-tested at scale.** Hundreds of connections and hundreds of streams per connection
  are tested; thousands are not. The Room in heya is one process per room and would become the
  bottleneck around a hundred talkers; `Registry.dispatch` fan-out is the known next step.

## Where the next real value is

If one more thing were built, the best candidate is the **Plug/Bandit integration**: it would
turn karutte from "a WebTransport server you run beside your app" into "WebTransport in your
Phoenix app", which is the thing Elixir does not have and the thing most people would use.
Second best is a small **JavaScript client library** that mirrors the handler shape (a session
object with `streams()` and `datagrams()` and per-stream backpressure), because today every
client is hand-written against the raw WebTransport API.
