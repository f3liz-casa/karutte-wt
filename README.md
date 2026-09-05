# karutte-wt-next

The karutte monorepo. Three Elixir projects, side by side, each with its own `mix.exs`:

| Directory | What it is | Depends on |
|---|---|---|
| [`core/`](core/) | **karutte-core**: WebTransport over HTTP/3 for the BEAM, on quicer + cowlib. The library. Talks to real browsers. | quicer, cowlib |
| [`sukhi/`](sukhi/) | **karutte-sukhi**: Ed25519 admission tickets and a NATS-to-WebTransport bridge that pushes a fediverse server's live timeline. Plus `wt-relay/`, a transparent L4 relay for the front line. | `core/` |
| [`heya/`](heya/) | **heya** (部屋, "room"): an audio-only room opened from a Zulip call link. Voice is Opus over WebTransport datagrams; the koe voice agent joins over plain TCP. | `core/`, `sukhi/` |

`core/` is the part meant for other people. `sukhi/` and `heya/` are one deployment's business,
kept here because they are the honest examples of what the library is for. Path dependencies
point sideways (`../core`, `../sukhi`), so everything builds from a checkout with no publishing step.

```sh
(cd core  && mix test)   # 58 tests, real QUIC on localhost
(cd sukhi && mix test)   # 12
(cd heya  && mix test)   # 10
```

quicer builds msquic from source on the first `mix deps.compile` in each project. It takes a
few minutes and needs cmake, ninja, a C compiler, perl and OpenSSL headers.

## Where to start

- To **use** WebTransport from Elixir: [`core/README.md`](core/README.md). Quick start, options,
  how to write a handler, how to serve several handlers from one port.
- To see a **handler that pushes events** (one NATS subject = one unidirectional stream, with
  independent flow control): [`sukhi/lib/karutte/bridge.ex`](sukhi/lib/karutte/bridge.ex).
- To see a **datagram application** (voice, one process per participant, a room that never
  looks at the bytes): [`heya/lib/heya/`](heya/lib/heya/).
- For **what else this could be used for**: [`IDEAS.md`](IDEAS.md).

## Language

READMEs and the `core/` module docs are English. The deeper design documents
(`core/docs/*.md`, `sukhi/docs/`, `sukhi/wt-relay/docs/`) and the `sukhi/` and `heya/`
code comments are still Japanese. They are where the reasoning lives, and translating them is
slower work than translating the front pages. If you read Japanese and find a misreading, say so.

## About

The design and the skeleton were drafted by Shiro (Claude), an AI assistant working alongside
[@nyanrus](https://github.com/nyanrus).
