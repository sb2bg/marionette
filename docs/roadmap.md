# Roadmap

This roadmap is the source of truth for what Marionette is working on, what is
done, and what is deliberately deferred. It is written so that a contributor
can pick a task and know exactly what "done" looks like.

If you are a contributor: start with [Active Work Queue](#active-work-queue)
and pick any unassigned item. The top four are the most load-bearing.

If you are jumping back into the project after a break: read
[Current Status](#current-status) first, then
[Active Work Queue](#active-work-queue), then the
[Design Decisions](#design-decisions) section for the reasoning behind recent
architectural calls.

---

## Current Status

**Phase 0 (proof of concept) is effectively complete.** Pending a formal audit, the
project treats Phase 0 as closed.

**Phase 2 (multi-node network) is partially built ahead of Phase 1 (disk).**
This is a deliberate inversion of the original roadmap order. The network
primitives turned out to be the most interesting correctness story to prove
early, and the replicated-register example pulled in that direction. Phase 1
(disk) work resumes after active network item 4 unless an adopter needs
single-node storage testing sooner.

The current network surface is:

- `mar.UnstableNetwork(Payload, NetworkOptions)`: packet core with declared
  topology, per-link queues, send-time drops, latency with jitter, link/node
  state, and per-path clogging.
- `mar.UnstableNetworkSimulation(Payload, NetworkOptions)`: thin simulator
  wrapper exposing `packetCore()` (harness view) and `network()`
  (simulator-control view).
- `sim.tick()`: outer tick that advances `World` and evolves subsystem fault
  state. `sim.runFor(duration)` steps tick by tick rather than jumping time.

What is not built yet: app-facing `env.network()`, probabilistic tick-evolved
network faults, trace summary rendering, disk, crash/restart simulation,
liveness mode, named simulation profiles, linearizability checker, time-travel
debugging.

### Shipped primitives (stable enough to build on)

- `World`: clock, seeded PRNG, trace log, event indexes.
- `Clock`: production (host IO clock) and simulation (fake tick-based).
- `Random`: seeded PRNG wrapper.
- `mar.run` / `mar.runWithState`: twice-and-compare deterministic runner.
- `RunOptions`, `RunFailure`, `RunReport`, `StateCheck`, named `Check`.
- Replay-visible run profile, tags, and typed attributes.
- `mar.tidy` linter for banned direct calls.
- `BuggifyRate` + `env.buggify(hook, rate)` with enum-hook checks.
- Trace format with per-line validation (`isValidTracePayload`).
- Seed parser for decimal seeds and 40-character Git hashes.

### Shipped, marked unstable

- `mar.UnstableEventQueue`: fixed-capacity priority queue primitive.
- `mar.UnstableNetwork` / `mar.UnstableNetworkSimulation` / `mar.UnstableNetworkOptions`.

Unstable types will change without deprecation cycles until Phase 2 closes.

---

## Active Work Queue

Ordered by priority. Each entry has acceptance criteria, a rough size, and the
design context. Pick from the top unless coordinating otherwise.

### 1. Trace summary renderer

**Why now:** `sim.runFor` emits one `world.tick` event per tick. Once
probabilistic faults land in item 4, per-tick event volume grows again. The
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
  `network.*`, `register.*`, etc.), counts per specific event name within the
  top 8 most voluminous subsystems, a "singletons" list of event names that
  fired exactly once (long-tail surfacing).
- Replay context is echoed at the top of the summary: `run.profile`,
  `run.tag`, `run.attribute` pulled from the trace header.
- A dedicated network-aware breakdown: sends, drops by reason, deliveries,
  per-link send/deliver/drop counts.
- A test verifies the summary on a known trace snapshot (use the existing
  replicated-register smoke trace as input).
- `writeSummary` output is deterministic and diff-friendly.

**Files likely to change:**

- New: `src/trace_summary.zig`.
- Modify: `src/root.zig` (export `Summary`, `summarize`, `writeSummary`).
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

### 2. Fix `Cluster.sim = undefined` / `bindWorld` pattern

**Why now:** The replicated-register example has a `Cluster.init()` that
leaves `sim: Simulation = undefined`, then relies on `bindWorld(world)` being
called before any scenario body touches it. This is safe today only because
`runWithState` orders calls correctly. It will bite the moment a second
example needs the same setup. Fixing it while the example is still small and
while you're already looking at trace output (during item 1) is cheap.

**Scope:**

- Change `runWithState`'s `init_state: fn() State` signature to pass `*World`
  into state initialization. Either: (a) `init_state: fn(*World) State`, or
  (b) add a second entry point `runWithStateAndWorld` and keep the old one.
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

**Design note:** Option (a) is cleaner; option (b) avoids breaking any
external callers. Given that Marionette has no external callers yet, pick
(a).

---

### 3. Delete `PacketCore.drainUntilIdle`

**Why now:** After item 4 lands, `sim.drainUntilIdle` must be the only drain
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

### 4. Probabilistic tick-evolved network faults with stability floors

**Why now:** The outer `sim.tick()` is built and items 1-3 unblock safe
development. This is the next piece that makes VOPR-style swarm testing
possible.

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

Paused. Resume after item 4 lands, or earlier if an adopter needs single-node
storage testing. Items 5 through 8 are network backlog, not blockers for disk.

Read `docs/disk-fault-model.md` before starting any of these. The sub-tasks
below are ordered so each one is useful on its own.

### 9. `Disk` authority, no faults

Implement a `World`-owned disk authority with `write`, `read`, stable file
ids, per-operation ids, sector-aligned offsets, in-memory backing buffer
(sparse map, not a big flat allocation). Deterministic latency via a min +
jitter model, same shape as network latency. Trace events for every
submitted and completed operation.

### 10. Disk read/write faults

Per-sector fault bitmap. `BuggifyRate`-governed read fault, write fault,
and corruption probabilities. Explicit `sim.disk().corruptSector(file,
offset)` simulator-control API for scripted faults.

### 11. Crash-during-pending-write model

Pending writes that a crash can land, not land, or partially land per
sector. The crash-fault probability rises while writes are pending, per the
VOPR lesson.

Acceptance criteria should be phrased as disk/recovery invariants, not a
fault atlas: flushed writes are never lost, acknowledged unflushed writes may
be lost only according to the documented crash model, corruption is
trace-visible and reproducible, and replaying the same seed preserves the
same crash outcomes byte-for-byte.

### 12. Single-node example service that uses the disk

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

Keys and names are locked to `[a-z0-9_.]`. Values reject space, `=`,
newlines, tabs, and backslash. The `isValidTracePayload` assert fires on
every `record`. This keeps replay comparison byte-accurate and parsers
trivial. Never add escaping; the assert forces us to design event shapes
that don't need it.

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
