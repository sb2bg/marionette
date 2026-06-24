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

The long-term architecture is [Marionette as deterministic `std.Io`](std-io-direction.md):
production-shaped code should eventually accept `std.Io`, while Marionette
provides the deterministic implementation for tests.

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
- `World.simulate(.{ .network = ... })`: world-owned simulator network
  construction with `sim.control.network` for fault orchestration and
  `sim.endpoint(Message, node)` for typed app endpoints.
- `Production.endpoint(Message, opts)`: production-shaped local in-process endpoint
  with declared self id and peer topology; it is not a cross-process transport,
  and real socket backing is still future work.
- The internal packet core (`network/packet_core.zig`): declared
  topology, per-link queues, send-time drops, latency with jitter, link/node
  state, and per-path clogging.
- `sim.control.tick()`: outer tick that advances `World` and evolves subsystem
  fault state. `sim.control.runFor(duration)` advances through deterministic
  event and fault-evolution boundaries; long quiet spans may jump rather than
  emitting one tick per configured tick.
- `endpoint.receive()`: the public delivery loop primitive, routing time
  movement through the simulated network handle.

The current disk surface is:

- `mar.Disk`: lower-level disk capability exposing sector/file-lifecycle
  operations underneath the `std.Io` backend.
- `mar.SimDisk`: in-memory disk simulator with logical paths, sector-aligned
  reads/writes, sparse sectors, deterministic latency, operation ids, trace
  events, read/write IO errors, corrupt reads, and crash/restart behavior for
  pending writes.
- `mar.DiskControl`: harness-facing fault, scripted corruption, crash, and
  restart authority over the same `SimDisk` backing state.
- `World.simulate(...)`: constructs world-owned simulator resources and
  returns `{ env: Env, control: Control, io_runtime, process_supervisor }`.
- `Env.io()`: returns the host `std.Io` in production envs and Marionette's
  current deterministic `std.Io` backend in simulation envs. `sim.envForNode`
  returns per-node `Env` values backed by process-scoped `std.Io` backends.
  The simulation backend supports clock/random, scheduler-backed and
  trace-visible sleep, scheduler-backed `Io.async` / `Io.concurrent` / await,
  and immediate non-blocking `Io.Queue` operations today, plus an in-memory TCP
  stream subset for `std.Io.net` and a flat `std.Io.File` subset over
  `SimDisk`, including delete and rename. It fails closed for full
  directory/filesystem behavior, process operations, datagrams, DNS, and real
  external network access not yet routed through the simulator.
- `Env.disk`: low-level simulation disk view exposing sector-oriented `read`,
  `write`, and `sync`, plus file metadata and lifecycle operations. New
  storage examples should prefer `Env.io()` and `std.Io.File` unless they are
  intentionally testing the sector API.
- `examples/kv_store.zig`: disk-backed WAL recovery example with a passing
  checksum-validating mode and a deliberately buggy torn-record recovery mode.
- `examples/durable_broadcast.zig`: first disk + network cross-product
  example. It checks that quorum-acknowledged operations are recoverable from
  durable storage after crash/restart.

What is not built yet: a deterministic allocation authority and allocation
fault model, a real socket-backed production network adapter (scoped under
roadmap item 15, with `docs/network-production.md` as the target
architecture), liveness mode, named simulation profiles, named network buses,
linearizability checker, time-travel debugging.

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
- `mar.Disk`: concrete low-level disk capability.
- `mar.SimDisk`: deterministic disk simulator with replayable faults and
  crash/restart simulation.
- `mar.DiskControl`: simulator-control disk capability.
- `World.simulate`: world-owned simulator construction.
- Process-scoped simulation I/O: one backend per declared node, stable
  `envForNode(node).io()` identity, process-owned scheduler tasks, and
  `registerProcess`/`killProcess`/`restartProcess` lifecycle hooks.
- `Env.disk`: low-level simulation disk capability; `Env.io()` is the primary
  storage application surface.
- `mar.Endpoint(Message)`, `mar.NetworkControl`, `SimNetworkOptions`, and
  composition-root network accessors for simulation and production-shaped
  setup.
- Trace format with per-line validation (`isValidTracePayload`).
- Trace summary renderer (`mar.summarize`, `Summary.writeSummary`).
- Seed parser for decimal seeds and 40-character Git hashes.

### Shipped, marked unstable

- The internal fixed-capacity event queue (`scheduler.zig`) and packet core
  (`network/packet_core.zig`); both module-internal since the API prune.

Unstable types will change without deprecation cycles until Phase 2 closes.

---

## Recently Completed

These items were finished during the pre-disk stabilization pass.

### Completed: Trace summary renderer

**Status:** Done. `mar.summarize` and `Summary.writeSummary` are exported and
covered by tests.

**Why it mattered:** Early `runFor` paths emitted one `world.tick` event per
tick, and probabilistic faults add their own trace volume at evolution
boundaries. The summary layer has to exist before trace volume outpaces human
reading, not after.

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
- `crash` deterministically lands, loses, tears, or reorders pending writes
  according to `DiskFaultOptions`.
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

### Completed: Low-level simulation disk capability

**Status:** Done. `World.simulate` exposes a low-level disk capability through
`Env.disk`; the current teaching surface for storage-shaped application code is
`Env.io()` and `std.Io.File`.

**Scope:**

- Disk-model code can depend on `env.disk` for sector `read`, `write`, and
  `sync`, plus file metadata and lifecycle operations.
- Tests and harnesses access simulator-control operations such as `setFaults`,
  `crash`, `restart`, and `corruptSector` through `mar.DiskControl`.
- Current storage examples keep ordinary file I/O on `std.Io` and simulator
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

- Remove the callback-shaped public drain surface.
- Keep packet-core delivery helpers confined to low-level network tests.
- Update the replicated-register example to use endpoint `receive()`.

**Acceptance criteria:**

- No public `drainUntilIdle` remains.
- The replicated-register example has no `DeliveryContext`.
- All tests pass.

**Files likely to change:**

- `src/network/sim.zig`.
- `src/network/tests.zig`.

**Size:** ~30 lines.

---

### Completed: Probabilistic tick-evolved network faults with stability floors

**Status:** Done. Network control now has focused lossiness, latency, clog,
and partition-dynamics setters. Clogs and automatic node-isolating partitions
are tick-evolved and have stability floors. The replicated-register example
has a swarm fuzz scenario that exercises the profile.

**Why it mattered:** The outer `sim.control.tick()` is built and the
packet-core drain bypass is gone. This was the first scalable seeded-fault
slice and the proof point for VOPR-style swarm testing.

**Follow-up:** generalize the same tick-evolution shape to process
crash/restart, reusable profiles, and fuzz/search coverage in the active
0.4 queue.

---

### Completed: WAL record helper and durable-broadcast scenario split

**Status:** Done. `examples/wal_record.zig` now provides example-local
fixed-size record framing with magic, id, payload bytes, and checksum.
`examples/kv_store.zig` and `examples/durable_broadcast.zig` use the helper
instead of carrying separate little-endian/checksum code.

**Why it mattered:** The KV and durable-broadcast examples had crossed the
point where duplicated WAL framing was useful as teaching material. A tiny
shared helper keeps the examples focused on recovery behavior while still
making corrupt/torn-record detection explicit user code.

**Also done:** Durable broadcast now has separate network-fault,
crash-recovery, and multi-record scenarios, so future swarm/search runs can
target one behavior at a time and recovery bugs after record zero are
reachable.

---

### Completed: Process crash/restart probabilities

**Status:** Done. `sim.control.process.setDynamics(node, ...)` adds per-node
crash and restart rates with stability floors. The existing manual
`registerProcess`/`killProcess`/`restartProcess` lifecycle hooks remain, and
the same manual kill/restart operations are also available through
`sim.control.process`.

**Why it mattered:** Process failures now evolve through the same traced
control boundaries as network faults. `sim.control.runFor(...)` considers both
network and process fault boundaries, so long quiet spans still jump while
automatic crashes and restarts occur at their scheduled simulated timestamps.

**Coverage:** Tests cover validation, stability floors, runFor boundary jumps,
same-seed trace determinism, and `error.ProcessNotRegistered` when an
automatic restart fires for a process with no registered lifecycle.

---

### Completed: `SimCase` simulation runner

**Status:** Done. `mar.SimCase(App)` standardizes the common simulation test
shape: app initialization receives `mar.Sim`, scenarios and checks receive
`*mar.SimCase(App)`, application state lives at `case.app`, and simulator
authority remains available through `case.control()`.

**Why it mattered:** Examples no longer need to define a custom harness just to
call `World.simulate`, keep `control`, and store the application state. The
lower-level `runCase` path remains available for raw `World` tests and unusual
ownership.

**Coverage:** Runner tests cover pass, fuzz, expected failure, state checks,
app deinit, app-init errors, and the replicated-register example now uses
`runSimCase`/`expectSim*`.

---

### Completed: Scalable seeded fault evolution

**Status:** Done. `SimControl` coordinates a fixed set of private
fault-evolution participants rather than naming network and process separately
throughout the run loop. Every participant invocation has a
`fault_evolution.boundary` trace record, and large quiet jumps stop only at
participant-reported boundaries.

**Why it mattered:** Network and process dynamics now share one time-evolution
contract while disk read/write and crash rolls remain explicitly
operation-shaped. Equal elapsed time through `tick()` and `runFor()` preserves
the seeded random stream even across deterministic clog expiries.

**Coverage:** Tests cover combined network/process evolution, byte-identical
same-seed replay, traced transition boundaries, large quiet jumps, and
tick-versus-runFor RNG equivalence at clog expiry.

---

## Active Work Queue

0.4 should make the current simulator feel coherent rather than merely broad:
seeded faults evolve at stable control boundaries, common scenarios can select
named profiles, and examples prove bug discoverability with small fuzz/search
sweeps.

Pick from the top unless coordinating otherwise. Code work belongs in these
items; docs-only edits should keep the story current without claiming future
implementation as done.

### 1. Named simulation profiles

Lift the hand-built scenario settings into named profiles so examples and CI
can say what kind of run they are performing without rewriting rates and
budgets at every call site.

Acceptance criteria:

- Ship at least `baseline`, `swarm`, `replay`, and `performance` profiles.
- Profiles expand into `RunOptions`, simulator topology defaults, and runtime
  fault controls without hiding the fully expanded values from traces or
  failure summaries.
- Keep `replay` exact: a seed plus expanded profile should be enough to
  reproduce a failure.
- Port the replicated-register swarm setup to the shared profile mechanism
  without weakening its current coverage.

### 2. Fuzz/search confidence for known-bug examples

The suite has strong single-seed demonstrations. 0.4 should add modest
fuzz/search coverage where the bug is probabilistic, so CI proves the fault
profiles can discover known failures rather than only replay scripted failures.

Acceptance criteria:

- Add a durable-broadcast buggy fuzz/search variant where crash loss is
  probabilistic instead of `.always()`.
- Keep stable single-seed failure tests for readable traces.
- Decide whether replicated-register and KV need matching bug-search tests, or
  document why their deterministic demonstrations are enough for 0.4.
- Failure reports must include seed, profile name, and expanded profile values.

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

### 4. External storage-engine parity follow-ups

The first external-storage compatibility gap has mostly been closed:
Marionette now has file size metadata, EOF-aware reads, truncate/clear,
delete, rename, directory sync modeling, a flat `std.Io.File` subset over
`SimDisk`, and pinned xitdb validation coverage. The remaining work is no
longer the base disk lifecycle surface; it is confidence-building around
external storage engines and crash profiles.

Current partial progress: `Disk` now exposes path-level `stat`, EOF-aware
`readSome`, `setLength`, `delete`, `rename`, and `syncDir`, backed by both
`SimDisk` and `RealDisk`. Simulation `Env.io()` exposes the corresponding flat
`std.Io.File` subset over `SimDisk`: create/open, access/statFile, positional
and streaming read/write, length/stat, setLength, sync, close, delete, and
rename. A pinned external xitdb validation target now exercises a real
`std.Io.File` database workload with `zig build validate-xitdb` without adding
xitdb to the default test path. This is still not a complete filesystem model:
directory metadata/iteration, full `std.Io.Dir` sync plumbing, and richer
directory APIs remain deferred.

Acceptance criteria:

- Done: add a `Disk.stat` metadata operation that returns file size. It is
  deterministic, trace-visible, and backed by both `SimDisk` and `RealDisk`.
- Done: add an EOF-aware `readSome` shape for variable-length files. The
  sector-oriented `read(..., buffer)` still zero-fills short reads; `readSome`
  distinguishes EOF by returning a byte count.
- Done: add `setLength` for WAL reset. The first slice rejects while crashed
  and commits pending writes for the affected path before mutating metadata.
- Done: add `delete` for WAL cleanup and `rename` for compaction-style
  replacement. Directory-entry metadata is pending until `Disk.syncDir`, so
  crashes can roll back unsynced create/delete/rename metadata.
- Done: keep logical paths rooted in Marionette's disk namespace. No host
  absolute paths or current-working-directory behavior leaks into app code.
- Done: update `RealDisk`, `SimDisk`, trace events, docs, and `std.Io` tests
  together.
- Done: add explicit parent-directory durability modeling. Creates, deletes,
  and renames have pending metadata state plus a directory sync boundary, which
  exposes the real "file content fsynced but directory entry lost" bug class.
- Done: add a pinned lazy external validation target for xitdb. It creates an
  xitdb file database over `sim.env.io()`, performs modeled randomized
  transactions against a fixed keyspace, verifies every recovered history moment
  against the model, reopens after trailing junk so xitdb truncation runs, and
  asserts same-seed Marionette traces are byte-identical.
- Done: add a first xitdb crash-recovery check with `crash_lost_write_rate =
  .always()`. Acknowledged transactions are modeled as durable and verified
  after crash/restart, which exercises xitdb's sync-before-ack contract.
- Done: add a small lost-write seed sweep for xitdb acknowledged transactions.
  The pinned xitdb commit survived the sweep, which is positive evidence that
  file-backed commits sync before returning an acknowledged transaction.
- Done: add an xitdb immutability/MVCC-style check: hold a read-only cursor to
  an old moment, commit later transactions, and verify the old cursor still
  reads the old modeled snapshot.
- Done: add a SimDisk-vs-host-`std.Io` parity check for the same modeled xitdb
  workload.
- Done: add a layout-sensitive torn-write probe for xitdb's committed-size
  header. On the pinned xitdb commit and a deliberately non-realistic 7-byte
  simulated sector, Marionette exposes a minimal recovery counterexample: after
  one acknowledged transaction, a torn unacknowledged header write can make
  recovered reads fail with `EndOfStream`. The same probe currently recovers
  with 512- and 4096-byte simulated sectors. Since the committed-size field is
  fixed at bytes 28-35, it cannot cross a 512- or 4096-byte sector boundary;
  report this precisely as an atomicity-assumption counterexample, not a
  hardware-realistic data-loss bug.
- Done: add realistic data-region crash sweeps for xitdb at 512- and
  4096-byte sectors. The probe induces an unacknowledged xitdb write window,
  then crashes with torn or reordered pending writes and verifies recovery
  against the last acknowledged model state. The pinned xitdb commit survived
  the sweep, including trace-verified faults on data-region sectors rather than
  the committed-size header.
- Expand the xitdb crash-fault profile into a real fuzzer with shrinking. Vary
  sector size, crash point, workload length, and one active fault class at a
  time; reduce failures to a maintainer-readable operation sequence.
- Add a small compatibility scenario that ports the storage-facing slice of
  `kvdb` or a local surrogate with the same operations: open database, append
  WAL records, commit, reopen/recover, compact via rename, and clear/delete the
  WAL.

Design notes:

- Do not expose a full `std.fs.File` replacement. Keep the authority narrow and
  operation-shaped so every effect can be traced and faulted.
- Treat rename/delete/truncate as disk operations with recoverability
  semantics, not mere filesystem conveniences.
- If the exact crash semantics are unclear, land the no-crash deterministic
  behavior first and explicitly reject those operations while crashed; then add
  crash-window modeling as a follow-up.

### 5. Bug-detection fuzz coverage

**Moved to the active 0.4 queue.** Keep this section only as historical
context until the active item lands.

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

### 7. Crash / restart simulation

**Completed in the 0.4 queue.** Manual lifecycle hooks and tick/runFor-driven
process crash/restart probabilities now exist. Keep this historical entry only
as context for why process liveness is separate from network reachability:
`sim.control.process.*` owns logical process crashes and restarts, while
`sim.control.network.setNode(n, false)` remains a network availability fault.

### 8. Liveness mode transition

A one-shot `sim.transitionToLiveness(core: []const NodeId)` that zeroes
probabilistic fault rates, restores the core's links, brings the core's
nodes up, and leaves non-core failures permanent. See VOPR's
`transition_to_liveness_mode` for the reference shape. Depends on item 4
and item 5.

### 9. Named simulation profiles

**Moved to the active 0.4 queue.**

Ship `baseline`, `swarm`, `replay`, `performance` as first-class named
profiles that expand into `RunOptions`, `SimNetworkOptions`, and runtime
network fault controls. The replicated register example already manually
constructs these; lift them into the library. Depends on item 4.

### 10. Deterministic allocation authority and allocation-fault model

Allocation is already explicit in Marionette examples, but it is not yet a
simulated authority. That leaves two gaps: user code can still silently reach
for process-global allocators, and Marionette cannot yet model deterministic
OOM, quotas, or allocation-pressure bugs.

Do this before allocator behavior becomes baked into examples and before the
task scheduler creates more long-lived dynamic state.

Acceptance criteria:

- Define the app-facing shape: probably a standard `std.mem.Allocator` wrapper
  returned from `Env` or alongside `Env`, plus a production adapter that wraps
  a user-provided backing allocator with no faults by default.
- Define the harness-facing control surface: deterministic fail-after,
  quota/max-live-bytes, and optional `BuggifyRate` allocation failures. Fault
  configuration lives on `control`, not at each allocation call site.
- Trace allocation decisions without recording raw addresses: allocation id,
  requested length/alignment, result, live bytes, and failure reason are useful;
  pointer values are not replay-stable and must never enter the trace.
- Decide whether frees/reallocs are traced always or only under a verbose
  profile. The default should catch leaks and OOM behavior without making
  every trace unreadable.
- Add a linter default or documented project rule for global allocators such
  as `std.heap.page_allocator` in simulated code once the replacement API
  exists. Until then, projects can add that ban through `addTidyStep`.
- Add a small example or extend an existing one so an allocation failure is a
  real modeled branch, not only a unit test of the allocator wrapper.

Design notes:

- This should lean on Zig's `std.mem.Allocator` interface instead of inventing
  a Marionette-only allocation API if possible. The simulator value is in the
  backing policy, trace, and control surface.
- Deterministic allocator testing is about failure timing and resource
  pressure, not address determinism. Code that hashes or orders raw pointer
  identity is still banned by the determinism rules.
- Keep this separate from Marionette's own internal allocations at first.
  Internal trace and simulator bookkeeping may continue to use the run
  allocator; the modeled allocator is for user/application behavior.

### 11. Replace the `EventQueue` linear-scan pop with a heap

Not urgent. The comment in `scheduler.zig` already flags this. Do it when
benchmarking shows the scheduler is hot, or when a user picks it up as a
learning task.

### 12. Generalize `service_nodes` to `partitionable_nodes: []const NodeId`

`SimNetworkOptions.service_nodes: usize` is currently a prefix count: nodes
`0..service_nodes-1` are eligible for automatic node-isolating partitions.
This works for both current examples (services packed at low IDs, client
at the high ID) but it bakes a packing-order constraint into the API. It
cannot express:

- Non-zero-based service ranges (services `{2, 3, 4}`).
- Interleaved service/client topologies.
- Symmetric configurations where any node may be selected.

**Trigger for action:** when a third caller sets `service_nodes`, or when a
real example needs a non-prefix subset.

**Replacement:** `partitionable_nodes: []const NodeId = &.{}` (empty means
"all configured processes," matching today's `service_nodes = 0` default).
Migration is one PR that updates `SimNetworkOptions`, the auto-partition
selection in `evolveAutoPartition`, and every caller. Two callers today;
five-minute change. Cost grows linearly with new callers.

Hold until the third example forces the question. Do not pre-emptively
redesign for hypothetical layouts.

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

**15a. Wire format and framing primitive.** Started. Encode and decode helpers,
header and body checksums, roundtrip and corruption tests. No sockets. Lives in
`src/network/frame.zig`.

**15b. Buffer pool primitive.** Started. Refcounted preallocated message pool. Pool
exhaustion returns a hard error. Used by both sim and prod once integrated.
Lives in `src/message_pool.zig`.

**15c. Topology config and `Production.endpoint(Message, opts)`.** Started.
Production endpoint accepts peers and self id. It still returns the same
in-process FIFO behavior; the topology API change is the gate.

**15d. ByteEndpoint and codec bridge.** Started. `ByteEndpoint` exists for sim
and production setup with explicit ownership semantics: `send` copies borrowed
bytes, `sendMessage` transfers an acquired buffer, and `receive` returns a
releasable byte message. `ByteTransport` hides pool ownership for adapter
authors, and `CodecTransport(Codec)` gives protocol adapters typed send/receive
values with codec-declared receive lifetimes. This is the bridge for future Zig
network/RPC libraries that want Marionette as a backend without adopting typed
`Endpoint(Message)` directly. Keep `Endpoint(Message)` for value-message
examples; do not make borrowed slice payloads magically deep-copy.

**15e. Internal network IO seam.** Started. `src/network/io.zig` defines the
smallest backend shape the production bus needs so far: listen, connect, accept,
read, write, close, monotonic time, and sleep. Exact read/write helpers and a
fake backend cover short reads/writes and closed-peer behavior. Keep
`Endpoint(Message)` unchanged. A host socket adapter exists for the first
loopback transport slice.

**15f. Single-peer end-to-end socket transport.** Started.
`Production.byteEndpoint` uses framed loopback sockets when `.listen` is
configured. The old in-process FIFO remains for same-process production parity
setups without `.listen`. Loopback only; reconnect, background receive, and
multi-peer connection management are still future work.

**15g. Production-bus fake IO tests.** Exercise partial frame reads/writes,
EOF mid-frame, reconnect timing, and close discipline against the production
bus machinery without replacing normal `World` simulation.

**15h. Multi-peer with internal connection management.** Lazy outbound
connect, inbound listener, peer-type resolution from the first valid frame.

**15i. Reconnect with seeded jittered backoff.** Connection drop and
recovery tested end to end. Jitter seed comes from the local `NodeId` so
multiple peers reconnecting to a flapping node naturally desynchronize.

**15j. Bounded send and recv queues with silent-drop semantics.** Sim
reconciles to the same drop semantics as part of this step:
`error.EventQueueFull` becomes a trace-visible `network.drop reason=queue_full`
event in both impls, and `send` no longer surfaces transient errors.

**15k. Cross-process parity test.** The replicated-register example runs
on N OS processes, same source, same scenario, real sockets. This closes
item 15.

Steps 15a and 15b are independent and can land in parallel. 15c through
15k are sequential, except fake IO coverage can grow incrementally after
15e creates the internal seam.

### 16. Named-bus composition

Deferred until at least two independent examples have driven the shape.
Currently a single unnamed bus per message type is sufficient; many node
endpoints share that bus. The moment a second example needs both an RPC channel
and a gossip channel in the same process, this becomes blocking. Likely shape
is an explicit bus key on endpoint setup, as sketched in `docs/network-api.md`.

### 17. Multi-replica fault atlas

Add a VOPR-style cluster atlas that preserves recoverability invariants
across replicas. This belongs after the disk-backed replicated example exists.

### 18. Cooperative task scheduler and production task abstraction

Marionette now has a deterministic cooperative scheduler behind simulated
`std.Io`. `Io.async` and `Io.concurrent` enqueue single-future tasks, await
parks the current task or drives the scheduler from the scenario context, and
sleep, futex, and modeled network waits suspend through the same scheduler.
Runnable-task choices and suspension boundaries are trace-visible.

The production story is not "simulate cooperative tasks, then run arbitrary OS
threads and claim equivalence." Production backends should preserve as much of
the simulated contract as possible:

- **Single-thread cooperative event loop:** strongest parity. Same task/yield
  model as simulation, backed by real time and real IO.
- **Shared-nothing thread-per-core:** acceptable scale-out shape. Each OS
  thread owns its own scheduler/world-like state; cross-thread communication is
  message passing, not shared mutable state.
- **Preemptive user threads:** explicit escape hatch only. Marionette may help
  structure the logical concurrency, but it does not test memory-ordering,
  missed-wakeup, lock, or data-race bugs.

This scheduler tests logical concurrency: timeout-vs-response races,
message-order races, retries, elections, and IO interleavings at Marionette
authority boundaries. It does not test kernel thread scheduling or CPU memory
model behavior. That belongs to tools in the Shuttle/Loom family, not to
Marionette's DST contract.

Current status: the single-future cooperative path is implemented and used by
the Mailbox, bounded-queue, and `std.Io.net` KV validations. Remaining work is
cooperative cancellation points, `Io.Group`, queue suspension, broader I/O
suspension, and production-runtime parity. This remains cooperative scheduling,
not preemptive thread or memory-model simulation.

Design references that informed this item:

- [FoundationDB simulation testing](https://apple.github.io/foundationdb/testing.html):
  the clearest public writeup of single-process deterministic cluster
  simulation tied to an actor-style concurrency model.
- TigerBeetle internals:
  [ARCHITECTURE](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md),
  [TIGER_STYLE](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md),
  and VOPR internals. Focus on the single-threaded simulation boundary,
  weak transport contract, assertion discipline, and why correctness does not
  depend on simulating kernel threads.
- Seastar's shared-nothing model:
  [shared-nothing design](https://seastar.io/shared-nothing),
  [async tutorial](https://docs.seastar.io/master/tutorial.html), and
  [Seastar threads](https://docs.seastar.io/master/group__thread-module.html).
  Extract the production architecture lesson: one shard per core, explicit
  message passing, cooperative work units, no shared mutable state across
  cores.
- [madsim](https://docs.rs/madsim/latest/madsim/) and its
  [repository](https://github.com/madsim-rs/madsim): compare the Rust async
  runtime swap model against Marionette's explicit authority-passing style.

The implemented answers are deliberately narrow:

- The task primitive is the single-future `std.Io` async/concurrent/await path;
  cooperative cancellation points and `Io.Group` remain open.
- Yield points are modeled waits such as sleep, futex, network blocking, and
  scheduled disk-operation latency, with scheduler decisions and suspension
  outcomes recorded in the trace.
- Production parity still targets a cooperative event loop or shared-nothing
  thread-per-core design; preemptive threads are a documented guarantee
  demotion.
- Existing Marionette-native endpoint operations remain explicit authorities.
  Disk operations now park scheduled tasks behind latency deadlines while
  bare/non-task calls preserve synchronous `World.runFor` behavior.
- Deadlock and scheduler traces identify task ids, wait keys, deadlines, and
  runnable choices; richer minimized failure reports remain future work.

This is Flow/madsim-inspired in goal.

Implementation sequence:

1. Done: prove the bare fiber primitive and keep it behind a local seam.
2. Done: build a deterministic ready queue and run loop: current fiber, spawn,
   yield, completion, seeded runnable selection, and trace records for every
   scheduling decision.
3. Done: add futex wait sets: `futexWait` parks the current fiber on a key;
   `futexWake` wakes up to N fibers in seeded order. Raw futex addresses are
   mapped to stable logical keys before they enter the trace.
4. Done: add deterministic timed futex waits. A timed waiter wakes on either an
   explicit futex wake or its deadline; the losing path is cancelled by clearing
   the task's blocked key/deadline state. Equal-deadline timeouts wake in task-id
   order.
5. Done: add a pinned lazy Mailbox validation target. `zig build
   validate-mailbox` runs `g41797/mailbox` unmodified through Marionette's
   scheduler-backed `std.Io` and checks same-seed replay for timeout and
   send/wake paths.
6. Done: add an internal bounded-queue capability target. `zig build
   validate-bounded-queue` checks a FIFO/no-loss oracle across a seed sweep and
   keeps a planted close-path lost-wakeup bug that Marionette reports as a
   deterministic deadlock. This is a concurrency capability demonstration, not
   an external SUT finding.
7. Done: re-validate existing `std.Io` users, including xitdb, Mailbox, the
   bounded-queue oracle, the network KV harness, and storage examples under the
   scheduler-backed backend.

### 19. Scheduler-backed std.Io.net simulation

The scheduler/futex/timer work makes the first useful `std.Io.net` simulation
slice possible. This is distinct from roadmap item 15: item 15 is production
transport behind `Endpoint(Message)`, while this item is deterministic
simulation of ordinary `std.Io.net` stream code.

The initial target is intentionally narrow and based on Zig 0.16's actual
`std.Io` vtable:

- immediate: `netListenIp`, `netConnectIp`, `netClose`, `netShutdown`;
- suspending: `netAccept` when no connection is pending, and `netRead` when
  the peer remains open but no bytes are buffered;
- fail closed: DNS, Unix sockets, datagrams, socket pairs, `netSend`,
  `netWriteFile`, interface-name calls, and external host network access.

Implementation sequence:

1. Done: replace `simNetAccept`'s empty-queue `error.WouldBlock` with parking on a
   stable listener wait key, woken by `simNetConnectIp`.
2. Done: replace `simNetRead`'s open-peer `error.Timeout` stand-in with parking on a
   stable connection wait key, woken by `simNetWrite`, peer close, or a
   network delivery deadline.
3. Keep `Endpoint(Message)` and `std.Io.net` as sibling surfaces over
   simulator-owned network authority. Do not build sockets on top of typed
   endpoints and do not force typed endpoints through sockets.
4. Done for the first stream slice: route writes through the shared byte
   runtime so latency schedules delivery at a simulated timestamp and send-time
   loss wakes the peer with `error.Timeout` on the next empty read. Delivery-time
   manual-partition drops now wake the affected reader with `error.Timeout`, and
   healing permits deterministic retry on the same connection. Richer
   connection-reset and node-lifecycle behavior remains future work.
5. Done: add toy two-fiber server/client tests with connect/accept/read/write,
   latency, drop, partition/heal, and same-seed trace identity before looking
   for real networked SUTs.
6. Decided: do not inject byte reordering within one `std.Io.net` stream.
   The modeled stream is TCP and must preserve its byte-order contract.
   Reordering remains a message-altitude fault for `Endpoint(Message)`.
7. Done: add an external-style fixed-frame KV client/server validation whose
   SUT imports only `std`. The harness injects latency and a delivery-time
   partition, observes `error.Timeout`, heals the connection, retries the PUT,
   and checks exact-once application. A planted non-idempotent retry mode
   provides a seeded, byte-identical failure demonstration.
8. Done: preserve queued delayed bytes across graceful peer close so a reader
   drains accepted stream data before observing EOF.

This is a capability investment. The third-party `std.Io.net` ecosystem is
still thin. The first application-level proof is therefore external-style
ordinary Zig code rather than a third-party SUT finding. Keep the distinction
explicit until a compatible external target is validated.

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

### Cooperative tasks, not OS thread simulation

Marionette's scheduler runs spawned simulated tasks, deterministic sleeps, and
modeled I/O waits on one stable, seeded ready queue. This is the Zig-native
version of the lesson from FoundationDB Flow: production logic should be
testable under deterministic time, I/O, and scheduling.

Marionette will not build a new language or a preemptive user-thread runtime.
Simulated tasks are single-threaded and yield only at Marionette authority
boundaries such as sleep, network, disk, or explicit scheduler calls.

Production backends should prefer a real cooperative event loop or a
shared-nothing thread-per-core layout. Running the same logical tasks on
arbitrary preemptive threads is allowed only as a documented guarantee
demotion: Marionette still tests the protocol-level interleavings, but not
memory-level concurrency bugs. The deterministic guarantee only covers effects
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
`setLossiness`, `setLatency`, `setClogs`, `setPartitionDynamics`,
`setFaults` for aggregate replacement, `setNode`, `setLink`, `partition`,
`heal`, `healLinks`, `clog`, `unclog`, and `unclogAll`. Application-shaped
operations (`send`, `receive`) live on typed endpoints. No test-only operation
will ever leak into app-facing APIs.

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
  The vtable seam does not deliver that coverage. Sub-tasks 15d-15i
  should structure their syscalls behind a small internal IO abstraction
  so a deterministic impl is cheap to add later. The decision to ship
  one is deferred until 15d lands. See `docs/network-production.md`
  "Marionette's seam choice" for the reasoning.

The current production handle is a same-process FIFO adapter for shape
parity only; do not use it as evidence of cross-process transport support
until item 15j ships.

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
- **TLS, real DNS, arbitrary `std.net` compatibility.** The stable
  app-facing network remains narrower than `std.net`: it carries typed
  `Endpoint(Message)` traffic. Roadmap item 19 allows a narrow deterministic
  `std.Io.net` stream subset for simulation, but that is not a promise to
  model every host socket feature, protocol, resolver, or external network.
  Users who want raw production sockets should reach for `std.net` directly.
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

Last meaningful update: scalable seeded fault evolution and process
crash/restart probabilities are complete. The active 0.4 queue now centers on
named profiles and fuzz/search confidence.
Update this roadmap in the same PR as any substantive code change.
Contributors should expect the roadmap to reflect the true state of the code.
