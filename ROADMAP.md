# Roadmap

This file contains current and future work. Completed work belongs in
`CHANGELOG.md`; confirmed external bugs belong in `FOUND_BUGS.md`; open
simulator defects belong in `SIMULATOR_FINDINGS.md`.

## North Star

Marionette should make failures in Zig systems code reproducible, explainable,
and reducible while keeping application code shaped around `std.Io` and narrow
application-owned capabilities.

## Current: 0.6.3 — Expected-Failure Containment

Deadlock, cancellation, timeout, livelock, and non-yielding loops should become
structured outcomes instead of panics or frozen test processes.

Done means:

- cancelable disk-latency and file-lock waits consistently use cancelable
  scheduler paths;
- deadlock and cancellation preserve partial traces and compact wait state;
- a worker watchdog classifies non-yielding loops and preserves completed
  events;
- expectation helpers can require a failure kind, error, or check identity.

## 0.7 — Replay, Reduce, Explain

Turn a failure into a durable, minimal, executable artifact.

### Decision Tape And Replay

- Record globally ordered typed choices with stable semantic site IDs, logical
  time, microstep, alternatives, and selected value.
- Cover scheduling, network/disk faults, allocation, workload generation, and
  application randomness.
- Store build, target, SUT, model, options, seed, trace, failure fingerprint,
  and the decision tape in a versioned replay capsule.
- On divergence, report the first mismatched site and preceding causal event.

### Properties And Reduction

- Give properties stable IDs and deterministic safe-point lifecycles.
- Reduce decision/action groups while preserving the same failure fingerprint.
- Add causal event IDs, operation spans, compact deadlock cycles, and CI-ready
  artifact directories.

### Harness

- Add one concise high-level entry point that owns lifecycle, profiles,
  properties, replay, and artifacts.
- Keep application code on `std.Io`, `std.Io.Dir`, `Recorder`, and
  application-owned interfaces.
- Own routine process restart/reopen wiring without hiding expanded simulator
  options from artifacts.

## 0.8 — Guided Exploration

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
