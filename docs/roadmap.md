# Roadmap

This roadmap is intentionally conservative. Marionette is not claiming
determinism before the mechanisms exist.

## Phase 0: Proof Of Concept

Goal: prove deterministic replay works for a small Zig example and establish
the core interfaces.

Deliverables:

- Project skeleton pinned to the current Zig version.
- `Random` with explicit seeding.
- `Clock` with production and simulation implementations.
- `World` with a `SimClock`, seeded `Random`, and trace log.
- A small example service that uses clock and randomness.
- A fixed-seed determinism test comparing byte-identical traces.
- A many-seed fuzz test that prints the failing seed.
- A basic `tidy` linter for banned non-deterministic calls.
- A written architecture contract for determinism, time, randomness, and
  simulator scope.
- A twice-and-compare detector for runtime non-determinism.
- Public docs that are honest about what works and what does not.

Done means:

- `zig build test` passes deterministically.
- The same seed produces byte-identical traces across repeated runs.
- Debug and ReleaseSafe tests pass.
- A deliberately injected non-deterministic call is caught.
- A deliberately injected banned call is caught by the linter.
- Another Zig developer can understand the architecture in under 30 minutes.

## Phase 1: Single-Node MVP

Goal: make Marionette useful for a single-node service.

Planned work:

- Stabilize `Clock`, `Random`, and `Disk`.
- Add disk fault injection.
- Expand the AST-based linter with simple alias detection.
- Add docs on allocator discipline and banned standard-library calls.
- Add realistic examples such as a job queue or small KV store.

Done means a Zig service can adopt Marionette for reproducible single-node
testing with simulated time and disk faults.

## Phase 2: Multi-Node

Goal: simulate distributed systems in one process.

Planned work:

- Network interface.
- Packet delay, drop, reorder, and partition.
- Node spawning.
- Single-threaded cooperative scheduler.
- A real consensus or replication example.

Done means Marionette can test a small multi-node system under arbitrary
network faults with replayable traces.

## Phase 3: Production-Grade

Planned work:

- Linearizability checker.
- Time-travel debugging cursor.
- Seed shrinking.
- Trace export.
- Dependency audit tooling.

## Phase 4: Ecosystem

Planned work:

- Public case studies.
- Blog series.
- Talks.
- Compatibility guidance for Zig libraries.
- Potential hosted continuous simulation service.
