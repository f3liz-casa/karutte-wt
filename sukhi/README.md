# karutte-sukhi

The application [karutte-core](../core) was carved out of: the front line that pushes the
**sukhi** fediverse server's live timeline to browsers over WebTransport. The library is in
`core/`; only sukhi's own business is here.

## Layout

- **Root**: two modules and a runner.
  - `Karutte.Ticket` verifies admission tickets that sukhi signs with Ed25519. karutte holds
    only the public key, so every connection is checked locally, right after the TLS
    handshake, without asking sukhi. Cheap to refuse, which matters under a flood.
  - `Karutte.Bridge` is the WebTransport handler. It checks the ticket in `authorize/1`, and
    once the session is up it subscribes to one NATS subject per feed the ticket allows
    (`local`, `bubble`, `user`, `direct`) and opens **one unidirectional stream per feed**. A
    noisy feed cannot head-of-line block a quiet one, because each stream has its own flow
    control. Every event is one newline-delimited JSON frame.
  - `run.exs` starts the Bridge when `WT_TICKET_PUBKEY` is set, otherwise core's echo server.
- **`wt-relay/`**: a transparent L4 (WireGuard) relay and its control daemon, a separate
  runtime in a separate container. The data plane is the kernel (iptables / conntrack /
  WireGuard); the daemon only keeps the netfilter rules matching a declared spec and reports
  telemetry. It puts karutte behind a disposable public IP, preserves the real client address,
  and counts floods before decryption. Separate on purpose: the observer should outlive what
  it observes, and netfilter privileges should not sit in the front-line process.

## Running

```sh
mix test
```

`karutte_wt` is a path dependency on `../core`. The Dockerfile expects the monorepo root as
its build context:

```sh
docker build -f sukhi/Dockerfile -t karutte-sukhi .
```

## Documents (Japanese)

- [`docs/wt-relay-integration.md`](docs/wt-relay-integration.md): the karutte side of the edge
  path (transparent L4, real-IP preservation, origin hiding, floods).
- [`wt-relay/docs/edge-design.md`](wt-relay/docs/edge-design.md): the relay's design.

## About

Drafted by Shiro (Claude), an AI assistant working alongside [@nyanrus](https://github.com/nyanrus).
If something here is a misreading, please say so.
