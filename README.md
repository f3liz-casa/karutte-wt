# karutte-core

**WebTransport over HTTP/3 for Elixir, on real QUIC, talking to real browsers.**

karutte-core is a small, layered WebTransport server for the BEAM. It sits on
[quicer](https://github.com/emqx/quic) (msquic bindings) for QUIC and on
[cowlib](https://github.com/ninenines/cowlib) for HTTP/3 framing and QPACK, and adds only the
WebTransport-specific parts: Extended CONNECT, session and stream multiplexing, datagrams, and
a runner that maps each stream to its own process.

> **Status: experimental.** It works end to end with Chrome, the test suite is green, and the
> design is written down. But it is young, the API may still move, and it has not carried
> production traffic for long. Please try it, and please tell us what breaks.

## Why this exists

There is no WebTransport server for Elixir that runs on the BEAM's own QUIC stack. Plug servers
(Bandit, Cowboy) stop at TCP. The existing options (requiem, wtransport-elixir) wrap a whole Rust
QUIC stack through Rustler and live beside Plug rather than with it. karutte-core takes the other
road: quicer + cowlib underneath, a small behaviour on top, and the runner in plain OTP so that
crash isolation and backpressure fall out of the process model instead of being bolted on.

The longer story (why it did not exist before, the layer model, the three axes of backpressure,
everything that has been verified, and the honest loose ends) is in
[`docs/design.md`](docs/design.md). Note that the design documents are currently in Japanese.

## What works today

- **End to end on real QUIC.** WebTransport over HTTP/3 with a real browser (tested with Chrome 149).
- **Several WebTransport sessions on one HTTP/3 connection.**
- **One process per stream.** A crash in one stream handler does not take down its neighbours or the session.
- **Backpressure on three independent axes**: per stream (demand), per session (control plane), and datagrams (bounded queue, drop on overflow). They do not block each other.
- **Server-initiated streams** (uni and bidi), so you can push.
- **Graceful drain**: sessions being drained refuse new streams with a reset, existing ones finish.
- **An `authorize/1` gate** on CONNECT: accept or reject with a status before a session is created.
- **Telemetry** under `[:karutte, :http3, ...]` for connections, sessions, and datagram drops.

## What it needs

- Elixir 1.17 or newer, on a recent OTP (tested on OTP 27 and 28).
- A C toolchain for quicer, which builds msquic from source: `cmake`, `ninja`, a C compiler,
  `perl` and OpenSSL headers. On Debian/Ubuntu: `build-essential cmake ninja-build perl openssl`.
  The first `mix deps.compile` takes a few minutes. After that it is cached.
- A browser with WebTransport: Chrome and Edge have it, Firefox has it, Safari support is newer
  and less tested here.

## Installing

karutte-core is not on Hex yet. Add it as a git dependency:

```elixir
def deps do
  [
    {:karutte_wt, github: "f3liz-casa/karutte-core"}
  ]
end
```

(The OTP application is still called `:karutte_wt`. That name will settle before a Hex release.)

## Quick start: an echo server you can reach from Chrome

1. Generate a short-lived self-signed certificate and start the bundled echo handler:

   ```elixir
   {:ok, cert} = Karutte.Http3.Cert.generate("priv/cert")

   {:ok, _pid} =
     Karutte.Http3.Server.start_link(
       port: 4433,
       certfile: cert.certfile,
       keyfile: cert.keyfile,
       handler: Karutte.Http3.Echo
     )

   IO.puts("sha-256 (base64): " <> cert.sha256_b64)
   ```

2. In the browser, pin that hash and connect:

   ```js
   const hash = Uint8Array.from(atob("<the base64 printed above>"), c => c.charCodeAt(0));
   const wt = new WebTransport("https://localhost:4433/", {
     serverCertificateHashes: [{ algorithm: "sha-256", value: hash }],
   });
   await wt.ready;

   const s = await wt.createBidirectionalStream();
   const w = s.writable.getWriter();
   await w.write(new TextEncoder().encode("hi"));
   // read s.readable to get "hi" back
   ```

Browsers only accept `serverCertificateHashes` for ECDSA certificates valid for 14 days or
less. `Karutte.Http3.Cert.generate/1` produces exactly that, so it is meant for local
development. For anything public, pass a certificate from a real CA (Let's Encrypt works) as
`certfile` / `keyfile` and drop the hash pinning on the client.

There is also `run.exs` at the repo root, which starts the echo server with everything
configurable through environment variables (`WT_PORT`, `WT_BIND`, `WT_CERTFILE`, `WT_KEYFILE`,
and the limits below):

```sh
mix run --no-halt run.exs
```

## Putting it in your supervision tree

`Karutte.Http3.Server` is a supervisor with a `child_spec/1`, so it slots in like any other child:

```elixir
children = [
  {Karutte.Http3.Server,
   port: 4433,
   certfile: "priv/cert.pem",
   keyfile: "priv/key.pem",
   handler: MyApp.WebTransportHandler,
   max_sessions: 16,
   acceptors: 4}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Options

| Option | Default | What it does |
|---|---|---|
| `:port` | required | UDP port to listen on. |
| `:certfile`, `:keyfile` | required | PEM files for TLS. |
| `:handler` | required | Your `Karutte.WebTransport` module. |
| `:handler_arg` | `nil` | Passed to `handler.init/2`. |
| `:bind` | all interfaces | Listen on one address only. |
| `:acceptors` | `4` | Number of acceptor processes. |
| `:max_connections` | `10_000` | Upper bound on live QUIC connections. |
| `:max_sessions` | `16` | WebTransport sessions per HTTP/3 connection. |
| `:max_datagram_queue` | `1_000` | Datagrams buffered per session before dropping. |
| `:peer_bidi_stream_count`, `:peer_unidi_stream_count` | `256` | Streams the peer may open at once. |
| `:idle_timeout_ms` | `30_000` | QUIC idle timeout. |
| `:keep_alive_interval_ms` | off | Send QUIC PINGs at this interval (useful behind NAT or a relay). |
| `:alpn` | `["h3"]` | ALPN list offered. |
| `:name` | `Karutte.Http3.Server` | Registered name, if you run more than one. |

## Writing a handler

A handler has two faces. The **session** (control plane) decides what to do with each new
stream and each datagram, and never touches stream bytes itself. A **stream** module (data
plane) owns exactly one stream and lives in its own process.

The bundled echo handler is the smallest complete example, and is a fine starting point:

```elixir
defmodule MyApp.Echo do
  @behaviour Karutte.WebTransport

  @impl true
  def init(_arg, conn_info) do
    # conn_info carries the transport and connection handle; keep them if you
    # want to send datagrams or open streams from the server side later.
    {:ok, %{transport: conn_info.transport, conn: conn_info.conn}}
  end

  @impl true
  def handle_stream(_stream, _dir, state) do
    # Hand every incoming stream to its own long-lived process.
    {{:handler, MyApp.Echo.Stream, nil}, state}
  end

  @impl true
  def handle_datagram(bin, state) do
    state.transport.send_datagram(state.conn, bin)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defmodule Stream do
    @behaviour Karutte.WebTransport.Stream

    @impl true
    def init(_stream, _arg), do: {:ok, %{}, active: true}

    @impl true
    def handle_in(bin, state), do: {:push, bin, state, active: true}

    @impl true
    def handle_fin(state), do: {:close_write, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end
end
```

A few things worth knowing as you go further:

- **`authorize/1`** is an optional session callback. It receives `conn_info` (path, headers,
  peer address) before the session exists and returns `:ok` or `{:reject, status}`. It is the
  cheap place to turn away a request.
- **`:wt_ready`** arrives in `handle_info/2` once the session is up. That is where you open
  server-initiated streams with `transport.open_stream(conn, :uni)` or
  `open_stream(conn, :bidi, handler: Mod, init_arg: arg)`.
- **Inline streams.** Instead of `{:handler, Mod, arg}`, `handle_stream/3` can return
  `{:inline, max_bytes}`. The stream is then buffered up to that size and delivered whole to
  `handle_inline_stream/3` as one binary, with no extra process. Larger streams are reset.
- **`active:`** in a stream return is demand: `true`, `:once`, or a byte count. It is the
  per-stream flow-control window, so leaving it out is how you push back on the peer.

The callbacks are documented in `Karutte.WebTransport` and `Karutte.WebTransport.Stream`.

## Running the tests

```sh
mix test
```

The HTTP/3 loopback tests open real QUIC connections on localhost, so they need the quicer
NIF built and a free UDP port. Everything else runs on fake transports and is fast.

## Not done yet (honestly)

- **Only CONNECT is served.** Any other request gets a 404. This is a WebTransport server, not a web server.
- **No Plug integration yet.** There is a `Karutte.WebTransportAdapter` sketch for a future
  `Plug.Conn.upgrade_adapter(:webtransport, ...)` seam, mirroring WebSock, but today's server
  runs directly on quicer and does not go through Bandit or Plug.
- **The HTTP/2 transport is a fallback, not for browsers.** It exists so the behaviours can be
  exercised without QUIC. Datagrams over it are emulated (reliable and ordered).
- **Not battle-tested.** Load, long-running connections, and hostile peers have had some
  attention but not enough. Reports are very welcome.

## Documentation

- [`docs/design.md`](docs/design.md): why this did not exist, the layer model, backpressure, what has been verified, and the loose ends.
- [`docs/research-notes.md`](docs/research-notes.md): what we learned, in the order we learned it.
- [`docs/references.md`](docs/references.md): verified facts with sources (quicer API, RFCs, drafts).

These are in Japanese for now. English versions are on the list, and if you read Japanese and
spot a mistake, please say so.

## Related

- **karutte-sukhi**: the application this was carved out of. Ed25519 admission tickets, a
  NATS-to-WebTransport bridge for a fediverse server's live timeline, and a transparent L4 relay.
  Everything that is about one deployment rather than about WebTransport lives there.

## About this repository

The design and the skeleton were drafted by Shiro (Claude), an AI assistant working alongside
[@nyanrus](https://github.com/nyanrus). If something here is a misreading, please tell us.
