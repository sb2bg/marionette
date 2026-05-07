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

- `mar.Endpoint(Message)`: app-facing typed process endpoint with `send(to,
  message)` and `receive()`, returned by both simulation and production setup.
  `mar.Network(Message)` remains a compatibility alias.
- `World.simulate(.{ .network = ... })`: world-owned simulator network
  construction with `sim.control.network` for fault orchestration and
  `sim.endpoint(Message, node)` for typed app endpoints.
- `Production.endpoint(Message, node)`: production-shaped local in-process endpoint for
  same-process parity tests; it is not a cross-process transport, and real
  socket backing is still future work.
- `mar.UnstableNetwork(Payload, NetworkOptions)`: packet core with declared
  topology, per-link queues, send-time drops, latency with jitter, link/node
  state, and per-path clogging.
- `sim.control.tick()`: outer tick that advances `World` and evolves subsystem
  fault state. `sim.control.runFor(duration)` steps tick by tick rather than
  jumping time.
- `endpoint.receive()`: the public delivery loop primitive, routing time
  movement through the simulated network handle.

The current disk surface is:

- `mar.Disk`: app-facing capability exposing only `read`, `write`, and
  `sync`.
- `mar.SimDisk`: in-memory disk simulator with logical paths, sector-aligned
  reads/writes, sparse sectors, deterministic latency, operation ids, trace
  events, read/write IO errors, corrupt reads, and crash/restart behavior for
  pending writes.
- `mar.DiskControl`: harness-facing fault, scripted corruption, crash, and
  restart authority over the same `SimDisk` backing state.
- `World.simulate(...)`: constructs world-owned simulator resources and
  returns `{ env: Env, control: Control }`.
- `Env.disk`: app-facing simulation disk view exposing only `read`,
  `write`, and `sync`.
- `examples/kv_store.zig`: disk-backed WAL recovery example with a passing
  checksum-validating mode and a deliberately buggy torn-record recovery mode.
- `examples/durable_broadcast.zig`: first disk + network cross-product
  example. It checks that quorum-acknowledged operations are recoverable from
  durable storage after crash/restart.

What is not built yet: a real socket-backed production network adapter
(scoped under roadmap item 15, with `docs/network-production.md` as the
target architecture), liveness mode, named simulation profiles, named network
buses, linearizability checker, time-travel debugging.

### Shipped primitives (stable enough to build on)

- `World`: clock, seeded PRNG, trace log, event indexes.
- `Clock`: production (host IO clock) and simulation (fake tick-based).
- `Random`: seeded PRNG wrapper.
- `mar.run`, `mar.runCase`, `mar.expectPass`, `mar.expectFailure`, and
  `mar.expectFuzz`: twice-and-compare deterministic runner.
  Stateful initializers receive the replay attempt's `World`; stateful
  scenarios and checks receive only state.
- `RunOptions`, `RunFailure`, `RunReport`, `StateCheck`, named `Check`.
- Replay-visible run names, tags, and typed attributes.
- `mar.tidy` linter for banned direct calls.
- `BuggifyRate` + `env.buggify(hook, rate)` with enum-hook checks and
  runtime rate validation in simulation.
- `mar.Disk`: concrete app-facing disk capability.
- `mar.SimDisk`: deterministic disk simulator with replayable faults and
  crash/restart simulation.
- `mar.DiskControl`: simulator-control disk capability.
- `World.simulate`: world-owned simulator construction.
- `Env.disk`: app-facing simulation disk capability.
- `mar.Endpoint(Message)`, `mar.NetworkControl`, `SimNetworkOptions`, and
  composition-root network accessors for simulation and production-shaped
  setup.
- Trace format with per-line validation (`isValidTracePayload`).
- Trace summary renderer (`mar.summarize`, `Summary.writeSummary`).
- Seed parser for decimal seeds and 40-character Git hashes.

### Shipped, marked unstable

- `mar.UnstableEventQueue`: fixed-capacity priority queue primitive.
- `mar.UnstableNetwork` plus `NetworkOptions` for packet-core work.

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
- Replay context is echoed at the top of the summary: `run.name`,
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

### Completed: Disk capability and simulator, no faults

**Status:** Done. `mar.SimDisk` is exported and covered by unit tests.

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
- `DiskOptions.min_latency_ns = null` defaults to the world's tick duration;
  explicit values are not rewritten.
- Trace-visible fault decisions with rate, roll, and fired fields.
- Default no-fault behavior unchanged.

**Follow-up:** crash-during-pending-write simulation landed as the next slice.

---

### Completed: Disk crash-during-pending-write model

**Status:** Done. `mar.SimDisk` now tracks pending writes and exposes
simulator-control `crash` and `restart` through `mar.DiskControl`.

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

**Next dependency:** use the WAL example to shape reusable recovery-window and
fault-budget APIs.

---

### Completed: Disk-backed WAL recovery example

**Status:** Done. `examples/kv_store.zig` is covered by example tests and the
example CLI.

**Scope:**

- Fixed-size append-only WAL records backed by the app-facing `mar.Disk`
  capability.
- One synced record that must recover exactly once.
- One unsynced record that may be lost, torn, or rejected after corruption.
- A strict recovery mode that validates checksums.
- A deliberately buggy recovery mode that accepts a torn record by checking
  only the magic value.
- Named checker catches the unsafe recovery behavior.

**Follow-up:** use this example to guide recovery-window and fault-budget
APIs.

---

### Completed: App-facing simulation disk capability

**Status:** Done. `World.simulate` exposes an app-facing disk capability
through `Env.disk`.

**Scope:**

- App code can depend on `env.disk` for `read`, `write`, and `sync`.
- Tests and harnesses access simulator-control operations such as `setFaults`,
  `crash`, `restart`, and `corruptSector` through `mar.DiskControl`.
- The KV example keeps app storage calls on `env.disk` and keeps simulator
  control on `Control`.
- Disk lifecycle is owned by `World`.
- `mar.RealDisk`: production disk adapter backed by a real root directory.
- `mar.Production`: production composition root that owns production
  capabilities and exposes `Env`.

---

### Completed: Fix `Cluster.sim = undefined` / `bindWorld` pattern

**Status:** Done. `runCase` now passes `*World` into state initialization,
stateful scenarios/checks receive only state, and the replicated-register
example constructs its harness inside `Harness.init(world)`.

**Scope:**

- Change the state initializer signature to `fn(*World) State`.
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
- Tests that call the stateful runner directly.

**Size:** ~100 lines.

**Design note:** Marionette had no external callers yet, so the existing
entry point changed instead of adding a compatibility wrapper.

---

### Completed: Replace callback drain with pull receive

**Status:** Done. The public network delivery primitive is pull-shaped. It was
originally `network.nextDelivery()` and is now node-scoped as
`endpoint.receive()`.

**Why it mattered:** Callback-shaped delivery made example code harder to read
and encouraged packet-core access. Pull receive keeps delivery top-to-bottom and
advances simulated time through the simulation wrapper.

**Scope:**

- Remove `UnstableNetwork.drainUntilIdle`.
- Make `NetworkSimulation.drainUntilIdle` internal.
- Update the replicated-register example to use pull-shaped receives.

**Acceptance criteria:**

- No public `drainUntilIdle` remains.
- The replicated-register example has no `DeliveryContext`.
- All tests pass.

**Files likely to change:**

- `src/network.zig`.

**Size:** ~30 lines.

---

## Active Work Queue

Ordered by priority. Each entry has acceptance criteria, a rough size, and the
design context. Pick from the top unless coordinating otherwise.

### Completed: Probabilistic tick-evolved network faults with stability floors

**Status:** Done. `NetworkFaultOptions` now includes tick-evolved per-path
clogs and automatic node-isolating partitions with stability floors. The
replicated-register example has a swarm fuzz scenario that exercises the
profile.

**Why now:** The outer `sim.control.tick()` is built and the packet-core drain bypass
is gone. This is the next piece that makes VOPR-style swarm testing possible,
and the first disk-backed recovery example is now in place.

**Scope:**

- Add a runtime `NetworkFaultOptions`/profile object separate from static
  `SimNetworkOptions` topology and capacity.
- Per-path clog probability per tick, with minimum clog duration.
- The first automatic partition strategy is narrow: isolate one random
  service node from all other service nodes and clients, hold it for at
  least `partition_stability_min_ns`, and heal only after an unpartition
  roll passes once the stability floor has elapsed.
- Partition probability per tick with `partition_stability_min_ns` floor.
- Unpartition probability per tick with `unpartition_stability_min_ns` floor.
- All rolls happen only inside `sim.control.tick()`, never inside `popReady` or
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

### 2. Recovery windows and disk fault budgets

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

### 3. WAL record framing helper

The KV and durable-broadcast examples both hand-roll fixed-size records,
checksums, and little-endian field helpers. That repetition has crossed the
threshold where guidance alone is not enough; extract a tiny helper rather than
letting a third example copy the same framing again.

Acceptance criteria:

- Add a small helper for fixed-size WAL records with magic, sequence/op id,
  payload bytes, and checksum.
- Migrate `examples/kv_store.zig` and `examples/durable_broadcast.zig` to use
  it, reducing duplicated encode/decode code in both examples.
- Document the helper with the same worked pattern: magic, key/sequence,
  payload, and checksum fields.
- Explain why corrupt/torn reads should be detected by user code, not inferred
  by Marionette.
- Link the guide from the KV and durable-broadcast example docs.

Design notes:

- Keep the helper small and explicit. It should not become a generic WAL or
  recovery framework.
- Establish a simple magic naming convention or registry comment while touching
  the framing code; `kv_store` uses `MKV1`, durable broadcast uses `MDB1`.

### 4. Bug-detection fuzz coverage

Most deliberately buggy examples are single-seed demonstrations. Add a small
fuzz/search layer where the bug is probabilistic, so the suite proves failures
are discoverable under realistic profiles rather than only under scripted
`.always()` faults.

Acceptance criteria:

- Add a durable-broadcast buggy fuzz/search variant where crash loss is
  probabilistic instead of `.always()`.
- Keep the existing deterministic buggy smoke test for stable failure traces.
- Decide whether replicated-register and KV should also get bug-search tests,
  or document why single-seed demonstration is enough for those cases.

### 5. Durable-broadcast scenario split and multi-record variant

The first durable-broadcast example intentionally compresses fault setup,
submit, crash/restart, recovery, heal, and rebroadcast into one scenario. Split
the coverage once the helper code is extracted so swarm runs can target one
behavior at a time.

Acceptance criteria:

- Add a short happy-path scenario that only submits under network faults and
  checks durable quorum acknowledgement.
- Keep a separate crash-recovery scenario for the scripted crash/recover/heal
  path.
- Add or sketch a multi-record variant so recovery bugs after record zero are
  reachable.

### 6. Crash / restart simulation

Extend `sim.control.tick()` to roll per-node crash and restart probabilities with
stability floors. Crashed nodes are already expressible via
`sim.control.network.setNode(n, false)`, but there is no tick-driven randomness
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
profiles that expand into `RunOptions`, `SimNetworkOptions`, and runtime
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

### 9. `Disk` capability and `SimDisk` authority, no faults

Done.

Implement a `World`-backed disk simulator plus an app-facing capability with
`write`, `read`, stable logical file identities, per-operation ids,
sector-aligned offsets, in-memory backing buffer (sparse map, not a big flat
allocation). Deterministic latency via a min + jitter model, same shape as
network latency. Trace events for every submitted and completed operation.

### 10. Disk read/write faults

Done.

Per-sector fault bitmap. `BuggifyRate`-governed read fault, write fault,
and corruption probabilities. Explicit `sim.control.disk.corruptSector(file,
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

### Completed: Disk + network replicated example beyond the register

**Status:** Done as a narrow first cut. `examples/durable_broadcast.zig`
combines the disk and network surfaces in one harness and includes a
deliberately buggy broadcast-before-sync scenario.

This is not a full Viewstamped Replication or Raft implementation. It is the
smaller cross-product example needed before those heavier protocols: a local
WAL write, quorum replication, crash/restart recovery, network faults, and a
checker that fails when a network-visible operation was not durable.

### 15. Real production network transport

Marionette's parity claim ("the same code runs in production and under the
simulator") is true only inside one OS process today. `Production.endpoint`
is a same-process FIFO. Closing the gap is a real engineering project, not
a thin wrapper over `std.net`.

The full target is in `docs/network-production.md`. Read it before picking
up any sub-task. The headline shape is "TigerBeetle MessageBus, behind
Marionette's existing `Endpoint(Message)` vtable": length-prefixed framing
with checksums, refcounted preallocated message pool, lazy outbound connect
with seeded jittered backoff, async close discipline, bounded per-peer
queues, silent-drop send on full queue and unreachable peer.

Implementation order. Each sub-task ships independently. Cross-process
parity is the done-signal.

**15a. Wire format and framing primitive.** Encode and decode helpers,
header and body checksums, roundtrip tests. No sockets. Lives in
`src/network_frame.zig`.

**15b. Buffer pool primitive.** Refcounted preallocated message pool. Pool
exhaustion returns a hard error. Used by both sim and prod once integrated.
Lives in `src/message_pool.zig`.

**15c. Topology config and `Production.endpoint(Message, opts)`.**
Production endpoint accepts peers and self id. Initially returns the same
in-process FIFO behavior; the topology API change is the gate.

**15d. Single-peer end-to-end socket transport.** Two processes, one peer
each, real send and receive over the new framing. Loopback only.

**15e. Multi-peer with internal connection management.** Lazy outbound
connect, inbound listener, peer-type resolution from the first valid frame.

**15f. Reconnect with seeded jittered backoff.** Connection drop and
recovery tested end to end. Jitter seed comes from the local `NodeId` so
multiple peers reconnecting to a flapping node naturally desynchronize.

**15g. Bounded send and recv queues with silent-drop semantics.** Sim
reconciles to the same drop semantics as part of this step:
`error.EventQueueFull` becomes a trace-visible `network.drop reason=queue_full`
event in both impls, and `send` no longer surfaces transient errors.

**15h. Cross-process parity test.** The replicated-register example runs
on N OS processes, same source, same scenario, real sockets. This closes
item 15.

Steps 15a and 15b are independent and can land in parallel. 15c through
15h are sequential.

### 16. Named-bus composition

Deferred until at least two independent examples have driven the shape.
Currently a single unnamed bus per message type is sufficient; many node
endpoints share that bus. The moment a second example needs both an RPC channel
and a gossip channel in the same process, this becomes blocking. Likely shape
is an explicit bus key on endpoint setup, as sketched in `docs/network-api.md`.

### 17. Multi-replica fault atlas

Add a VOPR-style cluster atlas that preserves recoverability invariants
across replicas. This belongs after the disk-backed replicated example exists.

### 18. Cooperative simulation scheduler

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

Users call `sim.control.tick()` (or `sim.control.runFor(duration)`). Each
subsystem exposes an internal fault-evolution hook called by that outer
simulation tick. No public
`sim.endpoint().tick()`, no public `sim.disk().tick()`. This avoids the
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
probability, crash probability) MUST live only inside `sim.control.tick()`. Running
them inside observation paths makes behavior depend on how often user code
calls into the simulator, which breaks determinism-by-simulated-time.

### Simulator-control is separate from the packet core

`Control.network` exposes only operations that make sense for a test harness:
`setFaults`, `setNode`, `setLink`, `partition`, `heal`, `healLinks`, `clog`,
`unclog`, `unclogAll`. Application-shaped operations (`send`, `receive`)
live on typed endpoints. No test-only operation will ever leak into
app-facing APIs.

### Real production network adapters are deferred, with a target

The app-facing typed endpoint exists for simulation and for same-process
parity tests. Real sockets are deferred but no longer open-ended.
`docs/network-production.md` records the target architecture and the
sub-task ordering (roadmap item 15). The headline shape is "TigerBeetle
MessageBus, behind Marionette's existing `Endpoint(Message)` vtable":
length-prefixed framing with checksums, refcounted preallocated message
pool, lazy connect with seeded jittered backoff, async close, bounded
per-peer queues, silent-drop send.

Settled choices, recorded so they don't get rediscussed:

- **The user-visible seam is the existing vtable.** Marionette will not
  parametrize `Endpoint(Message)` on an IO backend at the public API.
  The vtable already gives the sim/prod swap; adding a generic IO type
  would push library internals into every user call site.
- **Sim and prod converge on silent-drop send semantics.** Today's sim
  `error.EventQueueFull` becomes a trace-visible `network.drop
  reason=queue_full` event. Production drops the same way. The application
  retries.

Deferred, not foreclosed:

- **Internal IO parameterization for fuzzing the production bus.**
  TigerBeetle's `MessageBusType(IO)` exists primarily so `message_bus_fuzz`
  can exercise the *real* production bus code (framing, recv-buffer
  reassembly, connection state) against a deterministic test IO that
  simulates partial reads, EOF mid-frame, and similar IO-edge behaviors.
  The vtable seam does not deliver that coverage. Sub-tasks 15d-15g
  should structure their syscalls behind a small internal IO abstraction
  so a deterministic impl is cheap to add later. The decision to ship
  one is deferred until 15d lands. See `docs/network-production.md`
  "Marionette's seam choice" for the reasoning.

The current production handle is a same-process FIFO adapter for shape
parity only; do not use it as evidence of cross-process transport support
until item 15h ships.

### Trace format is strict ASCII, line-oriented, validated at write time

Keys and names are locked to `[a-z0-9_.]`. Raw `World.record` values reject
space, `=`, newlines, tabs, and backslash, and return
`error.InvalidTracePayload` when the formatted event is ambiguous.
`World.recordFields` is the path for runtime text such as disk logical paths:
it percent-escapes ambiguous bytes while preserving readable stable ASCII
where possible. This keeps replay comparison byte-accurate and parsers
simple without banning useful runtime labels.

### Topology is declared at simulation construction

`SimNetworkOptions.nodes` declares the process universe for composition-root
simulation. Every `NodeId` is bounds-checked against the declared topology. No
dynamic node spawning in the current surface. When dynamic topology is needed,
it is a separate primitive.

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
- **TLS, real DNS, arbitrary `std.net` compatibility.** The app-facing
  network is narrower than `std.net`: it carries typed `Endpoint(Message)`
  traffic and nothing else. The production transport (roadmap item 15)
  uses real sockets internally, but it is not a general socket library
  and will not expose stream or datagram primitives outside the
  `Endpoint(Message)` shape. Users who want raw sockets should reach for
  `std.net` directly.
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

Last meaningful update: TigerBeetle MessageBus study; roadmap item 15
restructured into production-transport sub-tasks (15a-15h) and named-bus
composition split into a separate item 16. See `docs/network-production.md`
for the target architecture. Update this roadmap in the same PR as any
substantive code change. Contributors should expect the roadmap to reflect
the true state of the code.
