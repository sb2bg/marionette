# Roadmap

This file contains current and future work. Completed work belongs in
`CHANGELOG.md`; confirmed external bugs belong in `FOUND_BUGS.md`; open
simulator defects belong in `SIMULATOR_FINDINGS.md`.

## North Star

Marionette should make failures in Zig systems code reproducible, explainable,
and reducible while keeping application code shaped around `std.Io` and narrow
application-owned capabilities.

## Next: 0.8 — Guided Exploration

- Add scheduler policies in order: random, exact replay, PCT, then bounded
  choice/preemption exploration.
- Add campaign budgets, shards, resume, corpora, stable failure deduplication,
  and JSON/JUnit output.
- Report semantic coverage across choices, properties, faults, process states,
  links, durability boundaries, and cancellation points.
- Add small-history linearizability checking and bounded crash-point campaigns.
- Add storage/network behavior only when a pinned SUT demonstrates the need.
- Promote typed endpoints only after a real SUT establishes their ownership,
  delivery, readiness, cancellation, close, and backpressure contract.

## 0.9 And 1.0 — Stabilize The Narrow Core

- Define application, harness, and model-author compatibility tiers.
- Narrow root exports around proven application and harness seams.
- Publish model, trace, tape, and artifact compatibility policies.
- Harden supported target/optimize matrices or explicitly narrow them.
- Benchmark scheduler/event scaling before replacing data structures.
- Make the external validation corpus release-blocking.

## Deferred Harness Work

- Add allocation-site stacks and generic user-resource tracking beyond the
  existing simulated-handle checks.

## Standing Decisions

### `std.Io` Is The Production Seam

Production-shaped SUT code accepts host `std.Io`; simulation substitutes the
deterministic backend. Marionette does not ship a production runtime or socket
bus. Harness fault powers stay out of application handles.

### Typed Messages Are Experimental

`std.Io.net` tests codecs, framing, partial I/O, stream lifecycle, and transport
glue. `Endpoint(Message)` explores protocol/state-machine behavior above the
wire. It is not a promise of production transport parity.

### Breadth Is SUT-Driven

UDP, Unix sockets, richer DNS, new storage profiles, extension hooks, and wider
protocol surfaces require evidence from a pinned SUT or concrete adopter.
Graphical debugging, DPOR, and scheduler rewrites wait for mature artifacts or
measurement.

## Contribution Gate

Changes must pass Debug, ReleaseSafe, and ReleaseFast tests, formatting, tidy,
relevant target checks, and applicable external validations. Model changes need
contract/state-machine coverage; ownership-changing fallible paths need
targeted failure coverage. Public or semantic changes update the relevant
contract documentation and versioning.
