# Roadmap

This roadmap is the source of truth for what Marionette is working on, what is
done, and what is deliberately deferred. It is written so that a contributor
can pick a task and know exactly what "done" looks like.

If you are a contributor: start with [Active Work Queue](#active-work-queue)
and pick any unassigned item. The top items are the most load-bearing.

If you are jumping back into the project after a break: read
[Current Status](#current-status) first, then
[Active Work Queue](#active-work-queue), then the
[Design Decisions](#design-decisions) section for the reasoning behind recent
architectural calls.

---

## Current Status

**Phase 0 (proof of concept) is effectively complete.** Pending a formal audit, the
project treats Phase 0 as closed.

**Phase 2 (multi-node network) is partially built alongside Phase 1 (disk).**
This is a deliberate inversion of the original roadmap order. The network
primitives turned out to be the most interesting correctness story to prove
early, and the replicated-register example pulled in that direction. Phase 1
now has a deterministic disk authority with replayable faults and crash/restart;
probabilistic network faults remain valuable but are not a disk blocker.

The current network surface is:

- `mar.UnstableNetwork(Payload, NetworkOptions)`: packet core with declared
  topology, per-link queues, send-time drops, latency with jitter, link/node
  state, and per-path clogging.
- `mar.UnstableNetworkSimulation(Payload, NetworkOptions)`: thin simulator
  wrapper exposing `packetCore()` (harness view) and `network()`
  (simulator-control view).
- `sim.tick()`: outer tick that advances `World` and evolves subsystem fault
  state. `sim.runFor(duration)` steps tick by tick rather than jumping time.
- `sim.drainUntilIdle(...)`: the only public network drain helper, routing
  time movement through `sim.tick()`.

The current disk surface is:

- `mar.Disk`: in-memory disk authority with logical paths, sector-aligned
  reads/writes, sparse sectors, deterministic latency, operation ids, trace
  events, read/write IO errors, corrupt reads, scripted sector corruption, and
  crash/restart simulation for pending writes.
- `examples/kv_store.zig`: disk-backed WAL recovery example with a passing
  checksum-validating mode and a deliberately buggy torn-record recovery mode.

What is not built yet: app-facing `env.network()`/`env.disk()`, probabilistic
tick-evolved network faults, liveness mode, named simulation profiles,
linearizability checker, time-travel debugging.

### Shipped primitives (stable enough to build on)

- `World`: clock, seeded PRNG, trace log, event indexes.
- `Clock`: production (host IO clock) and simulation (fake tick-based).
- `Random`: seeded PRNG wrapper.
- `mar.run` / `mar.runWithState` / `mar.runWithStateLifecycle`:
  twice-and-compare deterministic runner.
  Stateful initializers receive the replay attempt's `World`; stateful
  scenarios and checks receive only state.
- `RunOptions`, `RunFailure`, `RunReport`, `StateCheck`, named `Check`.
- Replay-visible run profile, tags, and typed attributes.
- `mar.tidy` linter for banned direct calls.
- `BuggifyRate` + `env.buggify(hook, rate)` with enum-hook checks and
  runtime rate validation in simulation.
- `mar.Disk`: deterministic disk authority with replayable faults and
  crash/restart simulation.
- Trace format with per-line validation (`isValidTracePayload`).
- Trace summary renderer (`mar.summarize`, `Summary.writeSummary`).
- Seed parser for decimal seeds and 40-character Git hashes.

### Shipped, marked unstable

- `mar.UnstableEventQueue`: fixed-capacity priority queue primitive.
- `mar.UnstableNetwork` / `mar.UnstableNetworkSimulation` / `mar.UnstableNetworkOptions`.

Unstable types will change without deprecation cycles until Phase 2 closes.

---

## Recently Completed

These items were finished during the pre-disk stabilization pass.

### Completed: Trace summary renderer

**Status:** Done. `mar.summarize` and `Summary.writeSummary` are exported and
covered by tests.

**Why it mattered:** `sim.runFor` emits one `world.tick` event per tick. Once
probabilistic faults land, per-tick event volume grows again. The
summary layer has to exist before trace volume outpaces human reading, not
after.

**Scope:**

- A library helper, not a CLI. `fn summarize(trace_bytes: []const u8) Summary`
  and a stable `Summary.writeSummary(writer)` that matches the pattern of
  `RunFailure.writeSummary`.
- Snapshot-testable plain-text output.

**Acceptance criteria:**

- `Summary` contains: total event count excluding the trace header, final
  simulated timestamp (parsed from `world.tick now_ns` or `world.run_for end_ns`
  if the trace ever emitted one), counts grouped by subsystem (`world.*`,
  `network.*`, `register.*`, etc.), the top 8 most voluminous event names,
  a "singletons" list of event names that
  fired exactly once (long-tail surfacing).
- Replay context is echoed at the top of the summary: `run.profile`,
  `run.tag`, `run.attribute` pulled from the trace.
- A dedicated network-aware breakdown: sends, drops by reason, deliveries,
  per-link send/deliver/drop counts.
- A test verifies the summary on a known trace snapshot (use the existing
  replicated-register smoke trace as input).
- `writeSummary` output is deterministic and diff-friendly.

**Files likely to change:**

- New: `src/trace_summary.zig`.
- Modify: `src/root.zig` (export `Summary` and `summarize`).
- Modify: `tests/` (new snapshot test file).

**Size:** ~300 lines including tests.

**Design notes:**

- Parse the trace one pass, no backtracking. The format is line-oriented with
  `event=<n> <name> key=value...` and `isValidTracePayload` guarantees no
  escaping surprises.
- Do not try to interpret payloads semantically. Count what you see, group by
  the prefix up to the first `.` in the event name.
- Output format should be grep-friendly (one fact per line, stable key order).

---

### Completed: Disk authority, no faults

**Status:** Done. `mar.Disk` is exported and covered by unit tests.

**Scope:**

- Logical files addressed by trace-escaped paths.
- Operation ids.
- Sector-aligned offsets with a 4096-byte default sector size.
- Sparse in-memory sectors.
- Deterministic min + jitter latency.
- Trace events for `read`, `write`, and `sync`.
- Crash faults landed later as a separate completed slice.

---

### Completed: Disk read/write/corruption faults

**Status:** Done. `mar.DiskFaultOptions` is exported and covered by unit
tests.

**Scope:**

- Runtime `DiskFaultOptions` profile separate from `DiskOptions`.
- `BuggifyRate`-governed read errors, write errors, and corrupt reads.
- Explicit `corruptSector(path, offset)` simulator-control API for scripted
  sector corruption.
- Trace-visible fault decisions with rate, roll, and fired fields.
- Default no-fault behavior unchanged.

**Follow-up:** crash-during-pending-write simulation landed as the next slice.

---

### Completed: Disk crash-during-pending-write model

**Status:** Done. `mar.Disk` now tracks pending writes and exposes
simulator-control `crash` and `restart`.

**Scope:**

- Successful writes are visible to later reads immediately, but remain pending
  until `sync`.
- `sync(path)` commits pending writes for that logical path and traces how
  many writes became durable.
- `crash` deterministically lands, loses, or tears pending writes according to
  `DiskFaultOptions`.
- `restart` brings the disk back up; while crashed, `read`, `write`, and
  `sync` return `error.DiskCrashed`.
- Crash decisions and resulting write outcomes are trace-visible.

**Remaining gap:** a disk-backed service example that proves recovery behavior
against this model.

---

### Completed: Disk-backed WAL recovery example

**Status:** Done. `examples/kv_store.zig` is covered by example tests and the
example CLI.

**Scope:**

- Fixed-size append-only WAL records backed by `mar.Disk`.
- One synced record that must recover exactly once.
- One unsynced record that may be lost, torn, or rejected after corruption.
- A strict recovery mode that validates checksums.
- A deliberately buggy recovery mode that accepts a torn record by checking
  only the magic value.
- Named checker catches the unsafe recovery behavior.

**Follow-up:** use this example to guide any future `env.disk()` shape and
recoverability-budget API.

---

### Completed: Fix `Cluster.sim = undefined` / `bindWorld` pattern

**Status:** Done. `runWithState` now passes `*World` into state
initialization, stateful scenarios/checks receive only state, and the
replicated-register example constructs `Cluster.sim` inside
`Cluster.init(world)`.

**Scope:**

- Change `runWithState`'s `init_state` signature to
  `fn(*World) State`.
- Migrate the replicated-register example to construct `Cluster` fully in
  `init`, removing `bindWorld` entirely.

**Acceptance criteria:**

- No field in `Cluster` starts as `undefined`.
- No `bindWorld`-style method exists in the example.
- Both the existing scenarios (smoke, bug, partition, conflict) pass.
- Trace bytes are unchanged for the smoke scenario (byte-for-byte).
- State initialization must not record trace events; scenario execution owns
  trace output.

**Files likely to change:**

- `src/run.zig` (signature change).
- `examples/replicated_register.zig` (remove `bindWorld`).
- Tests that call `runWithState` directly (there are a few).

**Size:** ~100 lines.

**Design note:** Marionette had no external callers yet, so the existing
entry point changed instead of adding a compatibility wrapper.

---

### Completed: Delete `PacketCore.drainUntilIdle`

**Status:** Done. `sim.drainUntilIdle` is the only public network drain helper.

**Why it mattered:** `sim.drainUntilIdle` must be the only drain
path, because the packet-core version bypasses `sim.tick()` and silently
skips probabilistic fault evolution. Delete it before probabilistic faults
make the bypass dangerous.

**Scope:**

- Remove `UnstableNetwork.drainUntilIdle`.
- Keep `UnstableNetworkSimulation.drainUntilIdle`.
- Update the replicated-register example (already uses the sim version).

**Acceptance criteria:**

- The only public `drainUntilIdle` is on `UnstableNetworkSimulation`.
- All tests pass unchanged.

**Files likely to change:**

- `src/network.zig`.

**Size:** ~30 lines.

---

## Active Work Queue

Ordered by priority. Each entry has acceptance criteria, a rough size, and the
design context. Pick from the top unless coordinating otherwise.

### 1. Probabilistic tick-evolved network faults with stability floors

**Why now:** The outer `sim.tick()` is built and the packet-core drain bypass
is gone. This is the next piece that makes VOPR-style swarm testing possible,
and the first disk-backed recovery example is now in place.

**Scope:**

- Add a runtime `NetworkFaultOptions`/profile object separate from static
  `NetworkOptions` topology and capacity.
- Per-path clog probability per tick, with minimum clog duration.
- The first automatic partition strategy is narrow: isolate one random
  service node from all other service nodes and clients, hold it for at
  least `partition_stability_min_ns`, and heal only after an unpartition
  roll passes once the stability floor has elapsed.
- Partition probability per tick with `partition_stability_min_ns` floor.
- Unpartition probability per tick with `unpartition_stability_min_ns` floor.
- All rolls happen only inside `sim.tick()`, never inside `popReady` or
  `send`. Lazy expiry remains only for deadline-based deterministic clogs.
- All random draws are trace-visible through `world.randomIntLessThan`;
  network domain events record state changes.

**Acceptance criteria:**

- A scenario that sets runtime clog probability to `.percent(10)` and runs
  for N ticks produces the same trace bytes on two runs with the same seed.
- A scenario that sets `partition_stability_min_ns` prevents flip-flop: once
  a partition begins, the next unpartition roll is gated until the floor
  has passed.
- A swarm-style scenario in the replicated-register example exercises
  probabilistic clogs and completes successfully across ~100 seeds.
- Documentation in `docs/network.md` describes the probability model and
  gives a worked example.

**Files likely to change:**

- `src/network.zig` (rolls inside `evolveFaults`, new runtime fault options).
- `examples/replicated_register.zig` (new swarm scenario).
- `docs/network.md`.
- New test cases in `src/network.zig` and a fuzz test variant.

**Size:** ~400 lines including docs and tests.

**Design notes:**

- The rolls must be drawn from `world.randomIntLessThan` so they are seeded
  and traced.
- Stability floors are enforced by tracking `last_state_change_at_ns` per
  link (or per partition group) and refusing rolls until the floor is
  crossed.
- Do not fold automatic partitioning into the existing `partition(left, right)`
  control operation. Keep the explicit user-driven operation
  separate from tick-driven probabilistic evolution. User ops set state
  immediately; probabilistic evolution is governed by probabilities and
  stability.

---

## Near-Term Backlog

Items that are queued but not in the active hot path. Pick these up when the
active queue is drained or when they become blocking.

### 2. Environment-owned disk authority

The KV example validated `mar.Disk`, but it still constructs disk directly in
state. Add the smallest `SimulationEnv` disk ownership/access pattern once a
second disk-backed example or the production adapter shape gives enough signal.

Acceptance criteria:

- App code can depend on `env.disk()` instead of direct `mar.Disk` construction.
- Tests can still access simulator-control operations such as `crash`,
  `restart`, and `corruptSector` without leaking them into app code.
- Disk lifecycle is owned by the environment or state lifecycle, not by
  scenario-local cleanup.

### 3. Recovery windows and disk fault budgets

The KV example encodes recoverability in its checker. That is fine for the
first example, but reusable disk profiles need an explicit vocabulary for
"durable truth" and "allowed damage."

Acceptance criteria:

- Document a minimal recovery-window concept using the KV example as the
  worked case.
- Keep generic enforcement out of `mar.Disk` until at least one more storage
  example exists.
- Define how destructive disk fault budgets interact with synced vs unsynced
  writes.

### 4. WAL record framing guidance

The KV example hand-rolls fixed-size records and checksums. Do not promote a
library helper yet, but document the pattern so users do not accidentally test
storage without record identity validation.

Acceptance criteria:

- Add a short guide showing magic, key/sequence, payload, and checksum fields.
- Explain why corrupt/torn reads should be detected by user code, not inferred
  by Marionette.
- Link the guide from the KV example docs.

### 5. Crash / restart simulation

Extend `sim.tick()` to roll per-node crash and restart probabilities with
stability floors. Crashed nodes are already expressible via
`sim.network().setNode(n, false)`, but there is no tick-driven randomness
and no separation between "paused" and "crashed." Work this after item 4
so the probabilistic fault machinery is shared.

### 6. Liveness mode transition

A one-shot `sim.transitionToLiveness(core: []const NodeId)` that zeroes
probabilistic fault rates, restores the core's links, brings the core's
nodes up, and leaves non-core failures permanent. See VOPR's
`transition_to_liveness_mode` for the reference shape. Depends on item 4
and item 5.

### 7. Named simulation profiles

Ship `smoke`, `swarm`, `replay`, `performance` as first-class named
profiles that expand into `RunOptions`, `NetworkOptions`, and runtime
`NetworkFaultOptions`. The replicated register example already manually
constructs these; lift them into the library. Depends on item 4.

### 8. Replace the `EventQueue` linear-scan pop with a heap

Not urgent. The comment in `scheduler.zig` already flags this. Do it when
benchmarking shows the scheduler is hot, or when a user picks it up as a
learning task.

---

## Phase 1: Disk

Active. The disk-backed recovery example is also listed at the top of the
active work queue. Network items in the near-term backlog are not blockers for
disk.

Read `docs/disk-fault-model.md` before starting any of these. The sub-tasks
below are ordered so each one is useful on its own.

### 9. `Disk` authority, no faults

Done.

Implement a `World`-owned disk authority with `write`, `read`, stable logical
file identities, per-operation ids, sector-aligned offsets, in-memory backing buffer
(sparse map, not a big flat allocation). Deterministic latency via a min +
jitter model, same shape as network latency. Trace events for every
submitted and completed operation.

### 10. Disk read/write faults

Done.

Per-sector fault bitmap. `BuggifyRate`-governed read fault, write fault,
and corruption probabilities. Explicit `sim.disk().corruptSector(file,
offset)` simulator-control API for scripted faults.

### 11. Crash-during-pending-write model

Done.

Pending writes that a crash can land, not land, or partially land. Crash
outcome rates live in `DiskFaultOptions`; a future scheduler/fault profile can
make crash probability rise while writes are pending, per the VOPR lesson.

Acceptance criteria should be phrased as disk/recovery invariants, not a
fault atlas: flushed writes are never lost, acknowledged unflushed writes may
be lost only according to the documented crash model, corruption is
trace-visible and reproducible, and replaying the same seed preserves the
same crash outcomes byte-for-byte.

### 12. Single-node example service that uses the disk

Done.

A small append-only log, or a tiny KV store, that survives crash-faults at
any write boundary. This is the Phase 1 done-signal.

---

## Phase 2: Multi-Node (completion)

Work remaining beyond what already shipped.

### 13. Message-kind filters

Per-link command filters (VOPR: `EnumSet(Command)`). Gated on a generic
payload classification story: Marionette cannot assume the payload is an
enum. Options include a `Payload.command(self) enum` trait or a
user-provided `classify_fn`. Do not start this until a second network
example motivates it.

### 14. Replicated example beyond the register

A small Viewstamped Replication or Raft-shaped example. Strictly after
Phase 1 so the example has both disk durability and network faults.

### 15. App-facing `env.network()`

Deferred until at least two independent examples have driven the shape, or
until Zig's `std.Io` direction stabilizes enough to pick a production
adapter. Likely shape is documented in `docs/network-api.md`.

### 16. Multi-replica fault atlas

Add a VOPR-style cluster atlas that preserves recoverability invariants
across replicas. This belongs after the disk-backed replicated example exists.

### 17. Cooperative simulation scheduler

Spawn deterministic simulated tasks/nodes, route sleeps and simulated IO
through one scheduler, and trace every runnable-task decision. Production
routing may use a different backend, but simulation semantics define the
contract. This is Flow-inspired in goal, not a Flow clone.

---

## Phase 3: Production-Grade

Linearizability checker, time-travel debugging cursor, seed shrinking, trace
export, dependency audit tooling (banned calls in transitive deps). Each is
its own multi-week project; they will be broken into contributor-shaped
tasks when Phase 2 closes.

## Phase 4: Ecosystem

Case studies, blog series, talks, Zig-library compatibility guidance,
possible hosted continuous simulation service. Nothing code-shaped here
yet.

---

## Design Decisions

Durable rules that shape the work above. These are settled until someone
records a reason to reopen them.

### Library, not platform

No `LD_PRELOAD`, no syscall interception, no faketime, no patching of
transitive dependencies. Users write deterministic code against Marionette's
interfaces.

### Single-threaded simulated components

Non-negotiable through Phase 2, probably forever. Users who need parallelism
either run multiple `World` instances in separate threads or isolate the
parallel part behind an interface Marionette can simulate sequentially.

### Outer `Simulation.tick()` fans out; subsystem ticks are internal

Users call `sim.tick()` (or `sim.runFor(duration)`). Each subsystem exposes
an internal fault-evolution hook called by `sim.tick()`. No public
`sim.network().tick()`, no public `sim.disk().tick()`. This avoids the
footgun where users forget to tick one subsystem.

### Flow-inspired

Marionette may eventually grow a small cooperative task scheduler: spawned
simulated tasks, deterministic sleeps, deterministic IO waits, and one
scheduler choosing the next runnable task from a stable ordering. This is the
Zig-native version of the lesson from FoundationDB Flow: production logic
should be testable under deterministic time, IO, and scheduling.

Marionette will not build a new language or a preemptive user-thread runtime.
Simulated tasks are single-threaded and yield only at Marionette authority
boundaries such as sleep, network, disk, or explicit scheduler calls.

Production backends may eventually route the same high-level API to real IO or
event loops. The deterministic guarantee only covers effects
that go through Marionette authorities; arbitrary production thread races are
outside the simulator's model.

### Lazy expiry is a deterministic backstop, not a mechanism

Time-based deterministic expiry (like clog deadlines) may be evaluated
lazily inside `popReady` as a safety net. Probabilistic rolls (partition
probability, crash probability) MUST live only inside `sim.tick()`. Running
them inside observation paths makes behavior depend on how often user code
calls into the simulator, which breaks determinism-by-simulated-time.

### Simulator-control is separate from the packet core

`UnstableNetwork.Control` exposes only operations that make sense for a
test harness: `setNode`, `setLink`, `partition`, `heal`, `healLinks`,
`clog`, `unclog`, `unclogAll`. Application-shaped operations (`send`,
`popReady`) live on the packet core. No test-only operation will ever leak
into app-facing APIs.

### App-facing `env.network()` is deferred

`std.Io` is in flux; the design space (addressing, payload ownership, sync
vs callback, listener lifecycle) is large; one example isn't enough signal.
Do not commit to a shape before the second independent example forces it.

### Trace format is strict ASCII, line-oriented, validated at write time

Keys and names are locked to `[a-z0-9_.]`. Raw `World.record` values reject
space, `=`, newlines, tabs, and backslash, and return
`error.InvalidTracePayload` when the formatted event is ambiguous.
`World.recordFields` is the path for runtime text such as disk logical paths:
it percent-escapes ambiguous bytes while preserving readable stable ASCII
where possible. This keeps replay comparison byte-accurate and parsers
simple without banning useful runtime labels.

### Topology is declared at comptime

`NetworkOptions.node_count` and `NetworkOptions.client_count` are comptime
values. Every NodeId is bounds-checked against the declared topology. No
dynamic node spawning in the current unstable surface. When dynamic
topology is needed, it is a separate primitive.

---

## Deliberate Non-Goals

Things Marionette explicitly will not do, at least through Phase 2. Recorded
so they don't get rediscussed.

- **`libfaketime`, `LD_PRELOAD`, syscall interception.** See the library
  vs platform decision above.
- **Real thread scheduling.** Marionette is not Shuttle-for-Zig. That may
  become a separate sibling library; it will not be Marionette.
- **A Flow clone.** Marionette may borrow Flow's cooperative-simulation lesson,
  but it will not introduce a new language or require users to rewrite services
  in a Marionette-specific actor DSL.
- **Cross-process simulation.** In-process only.
- **TLS, real DNS, `std.net` compatibility.** The app-facing network will
  be narrower than `std.net`. If you need real sockets, you're not
  Marionette's user yet.
- **Unconstrained "chaos" disk faults.** All disk faults pass through a
  recoverability-aware fault model.
- **External dependencies.** Marionette depends only on Zig's standard
  library.
- **Feature-flag gating.** Code that is wrong is deleted, not gated.

---

## Contributor Guide

### Picking a task

Start with the [Active Work Queue](#active-work-queue). Items 1 through 4
are ordered for a reason; pick the highest unclaimed one unless you know
what you're trading off. Items 5+ are fair game if the active queue is
contended.

### What "done" looks like

A PR is done when:

1. `zig build test` passes.
2. `zig build test -Doptimize=ReleaseSafe` passes.
3. The `mar.tidy` linter passes.
4. The acceptance criteria listed on the task are all met.
5. Any public API change has a corresponding doc update in the relevant
   file under `docs/`.
6. If the task changes trace bytes, it includes an updated snapshot test
   rather than deleting the old one silently.

### PR shape

- One task per PR. Don't bundle unrelated changes.
- New files under 500 lines where possible.
- Tests live next to the code they test.
- Commit message style matches the existing log (short imperative title,
  one paragraph body if needed).
- No `TODO` without a tracking task in this roadmap or a GitHub issue.

### When a task turns out to be wrong

If you start a task and discover the scope or shape is wrong, stop, open a
discussion, and update this roadmap in the same PR as your fix. The
roadmap is the contract. Drifting from it silently is how small projects
become confusing.

---

Last meaningful update: after commit `86539ad Add simulation tick`. Update
this roadmap in the same PR as any substantive code change. Contributors
should expect the roadmap to reflect the true state of the code.
