# wt-relay

The control plane of a transparent L4 (WireGuard) relay. It keeps the relay's netfilter rules
matching a declared spec and reports telemetry. This is the underside that lets karutte sit
behind Cloudflare or on a disposable front-line box. A sister project of
[karutte-sukhi](..), and a **separate runtime**.

## The one property that matters: data plane in the kernel, control plane a gardener

Packets are forwarded and observed by the **kernel** (iptables / conntrack / WireGuard). They
never pass through userspace. So if this daemon (BEAM) dies, the `WT_RELAY` chain stays and
**the relay keeps flowing**. The control plane is not a gatekeeper but a gardener: it tends
the rules and watches, and never stands in the packets' way. That division is why a resident
daemon on a one-core front-line box is safe.

## Modules

- `WtRelay.Spec`: reads the desired state (routes) from a declaration, re-read every tick.
- `WtRelay.Route`: one L4 declaration. Two modes: transparent DNAT, and observe-only when
  karutte is on the same box.
- `WtRelay.Reconciler`: the gardener. Every tick, builds the desired `WT_RELAY` chain from the
  spec and fixes any drift.
- `WtRelay.Observer`: reads real counters from the kernel every tick and emits telemetry.

Design: [`docs/design.md`](docs/design.md) and [`docs/edge-design.md`](docs/edge-design.md)
(Japanese). Infrastructure notes in [`infra/`](infra/).
