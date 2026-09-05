# karutte-wt-next

The karutte monorepo. Three Elixir projects, side by side, each with its own `mix.exs`:

| Directory | What it is | Depends on |
|---|---|---|
| [`core/`](core/) | **karutte-core**: WebTransport over HTTP/3 for the BEAM, on quicer + cowlib. The library. | quicer, cowlib |
| [`sukhi/`](sukhi/) | **karutte-sukhi**: Ed25519 admission tickets and a NATS-to-WebTransport bridge for the sukhi fediverse server's live timeline, plus the `wt-relay/` L4 relay. | `core/` |
| [`heya/`](heya/) | **heya** (部屋): an audio-only room opened from a Zulip call link. Voice rides on WebTransport datagrams; koe joins over plain TCP. | `core/`, `sukhi/` |

`core/` is the part meant for other people. `sukhi/` and `heya/` are one deployment's business.
Path dependencies point sideways (`../core`, `../sukhi`), so everything builds from a checkout
with no publishing step.

```sh
(cd core  && mix test)
(cd sukhi && mix test)
(cd heya  && mix test)
```

quicer builds msquic from source on the first `mix deps.compile` in each project. It takes a
few minutes and needs cmake, ninja, a C compiler, perl and OpenSSL headers. See
[`core/README.md`](core/README.md) for the details, and for how to write a handler.
