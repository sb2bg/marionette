# Architecture

This document records Marionette's foundational correctness contract. If a
future feature weakens this contract, it needs an explicit design discussion.
For scheduler, network, invariants, or liveness work, read
[TigerBeetle Lessons](tigerbeetle-lessons.md) first. For network API work,
read [Network API Direction](network-api.md). For disk work, read
[Disk Fault Model](disk-fault-model.md) before writing code.

## Determinism Contract

Given the same Marionette version, Zig version, target platform, user code,
simulation options, and seed, a Marionette simulation must produce the same
declared result and byte-identical Marionette trace across repeated runs. The
guarantee applies only to behavior routed through Marionette-controlled
authorities: simulated time, seeded randomness, disk, network, future
scheduling, and explicit trace events. Marionette does not guarantee
stability for host wall-clock time, OS thread scheduling, stack or heap
addresses, pointer identity, unordered map iteration, external syscalls, data
read from real devices, or behavior from dependencies that bypass the
simulator. A nondeterminism leak is a correctness bug, not a flaky test.

## Current State

Marionette currently has:

- `World`, which owns one simulated clock, one seeded PRNG, and one trace log
  as harness-owned simulation engine state.
- `Clock(.production)` and `Clock(.simulation)`.
- `Env`, one concrete harness-facing bundle that supplies `std.Io`, recorders,
  disk, clock, random, and tracer capabilities.
- `Control`, the harness-facing counterpart for simulator-only controls.
- A seeded `Random` wrapper.
- A text trace format with a version header and global event indexes.
- `mar.runSimCase`, the primary stateful simulation runner, plus the
  lower-level `mar.run` for world-only scenarios. Both execute a scenario
  twice and compare traces.
- Run names, tags, and `RunAttribute`, which make expanded run facts
  replay-visible in traces and failure summaries without losing scalar value
  types. `runAttribute` is the constructor; keys are written explicitly so
  exported metadata names never silently track internal field renames.
- `mar.Check`, a named post-scenario check hook.
- `mar.SimCase` and `mar.StateCheck`, which let checks inspect structured
  scenario state initialized fresh for each replay attempt.
- An internal fixed-capacity deterministic event queue used by the network
  packet core for stable `(deliver_at, packet_id)`-style ordering.
- A seeded cooperative task scheduler with stable task ids, replay-visible
  selection, blocked wait sets, timed waits, deterministic wake ordering, and
  deadlock detection.
- A scheduler-backed `std.Io` futex path used by cooperative
  `Mutex` / `Condition` code, validated against the pinned `g41797/mailbox`
  target.
- An internal fixed-topology deterministic packet core with
  per-link queues, seeded packet loss, tick-aligned latency, process up/down
  state, directed link filters, simple partitions, and stable
  `(deliver_at, packet_id)` delivery order.
- Experimental `mar.Endpoint(Message)`, a typed process-model endpoint returned
  by simulation setup.
- A narrow scheduler-backed `std.Io.net` TCP-stream subset whose empty
  `accept` and `read` operations suspend, and whose bytes can traverse the
  shared network latency, loss, clog, and partition model.
- One process-scoped simulation `std.Io` backend per declared node, with stable
  `sim.envForNode(node).io()` identity, shared listener/connection registry,
  process-owned scheduler tasks, and explicit `killProcess`/`restartProcess`
  lifecycle hooks.
- `mar.Disk`, a lower-level disk capability for sector-oriented
  `read`/`write`/`sync` plus path-level metadata and lifecycle operations.
- `mar.SimDisk`, a deterministic disk simulator with logical paths,
  sector-aligned reads/writes, sparse in-memory sectors, deterministic
  latency, operation ids, trace events, read/write IO errors, corrupt reads,
  scripted sector corruption, and crash/restart simulation for pending writes.
- `mar.DiskControl`, the harness-facing fault, corruption, crash, and restart
  authority produced by `SimDisk.control()`.
- `parseSeed`, which accepts decimal seeds and 40-character Git hashes.
- Fixed-seed trace comparison tests.
- Many-seed deterministic fuzz-style tests.
- An AST-based tidy linter for obvious nondeterministic calls, including
  simple const aliases such as `const os = std.os;`.

Marionette does not yet have:

- Event-by-event invariant checking.
- Generic seed shrinking (the xitdb validation ships a domain-specific
  shrinker; the general mechanism is roadmap work).
- Syscall interception.
- Preemptive OS-thread or memory-model exploration.

## Source Layout

The top-level `src/` directory contains project-wide composition and runtime
modules. Subsystem implementation ownership is isolated under three directory
roots:

```text
src/
  disk/
    root.zig
    control.zig
    model.zig
    sim.zig
    real.zig
    tests.zig
  io/
    root.zig
    backend.zig
    file.zig
    net.zig
    futex.zig
    task.zig
    errors.zig
    tests.zig
  network/
    root.zig
    control.zig
    endpoint.zig
    sim.zig
    packet_core.zig
    types.zig
    tests.zig
```

Each subsystem `root.zig` is an internal aggregation boundary. The package's
only public entry point remains `src/root.zig`; application code imports the
`marionette` module rather than source files by path.

## IO Strategy

Marionette is a library-first simulator. User code should pass explicit
authorities at the top of the program instead of reaching for host globals.
The intended storage application shape is to accept `std.Io`, a root
`std.Io.Dir`, and optionally `mar.Recorder`. Code should accept all of
`mar.Env` only when it genuinely needs Marionette-specific capabilities such as
BUGGIFY, modeled allocation/disk operations, or trace recording.
Marionette should not auto-detect the environment from globals, environment
variables, thread-locals, or build flags.

`Env.io()` is the time, randomness, file, network, and scheduling seam: it
supplies a deterministic backend in simulation and the host backend in
production. App code can also receive typed `Endpoint(Message)` handles for
protocol modeling. See [std.Io Direction](std-io-direction.md) for the
destination architecture. The migration plan is:

- Keep Marionette's public effect surface narrow while `std.Io` is unstable.
- Model disk and network behind adapters that can wrap `std.Io` when its shape
  settles.
- Avoid promising compatibility with every `std.Io` operation or with raw OS
  calls that bypass it.
- Track Zig master and expect API churn before Zig 1.0.

If `std.Io` changes, Marionette should absorb that churn inside adapters, not
make every user rewrite their simulation tests.

## Time Model

Simulation time is an integer nanosecond virtual clock. There is exactly one
clock authority per `World`; application code reaches it through the
caller-provided `std.Io` instead of constructing a host I/O backend.

Current behavior:

- `now()` reads the world's current simulated timestamp.
- `tick()` advances by the world's configured tick duration.
- `runFor(duration)` advances through deterministic event and fault-evolution
  boundaries, and may jump across spans where no boundary exists.
- `std.Io.sleep(env.io(), duration, .awake)` uses the node-scoped scheduler
  authority: it parks an in-task caller or drives tasks from the main context,
  rounds to tick resolution, and crosses the same automatic-fault boundaries.
- `World.clock()` is the explicit low-level escape hatch. Its `SimClock`
  mutators move raw virtual time without running tasks or evolving faults.
- Time-evolved subsystems implement one private participant contract. The
  simulator records `fault_evolution.boundary` before invoking the fixed
  network and process participants, then asks the same participants for the
  next boundary. Adding another time-evolved subsystem does not add another
  hard-coded branch to the run loop.
- Scheduler timers, timed futex waits, and delayed network delivery advance
  time only when no task is runnable, jumping to the next deterministic event.

Sleeps, deadlines, timers, retries, network latency, and disk latency all route
through the world's clock. No subsystem may introduce a second clock.

This contract is for faults whose state evolves with simulated time, such as
automatic clogs, partitions, process crashes, and process restarts. Disk
read/write errors, corrupt reads, and crash outcomes remain operation-shaped:
their traced rolls occur when the corresponding disk operation or explicit
crash is performed, not at a time-evolution boundary.

## Randomness Model

There is exactly one seeded PRNG per `World`. Every simulator choice must draw
from it: packet latency, disk latency, BUGGIFY, crash timing, workload
generation, scheduling choices, and future shrink decisions.

Application random bytes, including `std.Random.IoSource` and
`std.Io.randomSecure`, flow through `Env.io()` into that PRNG and are recorded
as `io.random` events. BUGGIFY uses the same path.

Current `World.unsafeUntracedRandom()` exposes a raw deterministic
`std.Random` view for rare cases that need the full standard API. Draws
through that view are deterministic, but not automatically traced. The unsafe
name is intentional. Simulator decisions should use traced helpers such as
`randomU64()`, `randomBool()`, and `randomIntLessThan()`.

Independent host I/O backends, unseeded PRNGs, `/dev/urandom`, wall-clock
seeding, and raw host entropy are banned inside simulated code. The tidy
linter is the first guard. Twice-and-compare trace replay is the backstop. A
future paranoid mode should make simulator-incompatible effects fail loudly.

## Smallest User Program

The target shape is deliberately close to ordinary Zig dependency passing:

```zig
const std = @import("std");
const mar = @import("marionette");

fn client(env: anytype) !u64 {
    const io = env.io();
    var source: std.Random.IoSource = .{ .io = io };
    const latency_ns = source.interface().intRangeLessThan(u64, 0, 1_000_000);
    try std.Io.sleep(io, .fromNanoseconds(latency_ns), .awake);
    return latency_ns;
}

test "single request is replayable" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 0x1234 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const latency_ns = try client(sim.env);
    try sim.env.record("client.request latency_ns={}", .{latency_ns});
}
```

The same composition-root pattern is now used for networked examples: build a
simulation, pass `sim.envForNode(node)` into literal same-code socket paths or
node-scoped `Endpoint(Message)` handles into protocol models, and keep
`sim.control` in the harness.

## Production Cost And BUGGIFY

Fault hooks must not pollute production hot paths. The Zig shape is an
environment method:

```zig
if (try env.buggify(.drop_packet, .percent(20))) {
    return error.PacketDropped;
}
```

In simulation, `env.buggify` draws from the world's PRNG and records the
decision and rate. In production, `env.buggify` returns false and the branch
should fold away in optimized builds. Users call `buggify` because application
code knows domain-specific fault points that a generic simulator cannot infer.
Marionette decides whether the hook fires; user code owns the effect, such as
dropping a packet, delaying an operation, or returning a simulated storage
error. This is the Zig replacement for FoundationDB-style BUGGIFY macros.
[BUGGIFY](buggify.md) contains the current API shape and the remaining
production-codegen questions.

## Failure Surface

When Marionette finds a bug, the long-term minimum useful failure report is:

- Failing seed.
- Simulation options.
- Failure kind.
- Trace bytes or trace path.
- Last event index.
- Reproduction command.

Better reports will add shrinking and a reduced trace. A report that only says
`seed 0x1234 failed` is insufficient.

If a scenario returns an error, `mar.run` preserves the partial trace through
the last completed event in `RunReport.failed`. If a scenario panics, Zig's
default panic path may abort without giving Marionette a chance to flush
anything. Marionette documents that limitation plainly and should prefer
error-returning checks for simulated failures; a future custom panic hook can
improve crash traces.

Current `RunFailure` captures seed, options, failure kind, event counts, owned
traces, run name, tags, typed attributes, error name when available, and check
name when a named check failed. `RunFailure.writeSummary` is testable and backs
`RunFailure.print`. A future CLI wrapper should add an exact reproduction
command once the command-line surface exists.

## Exploration Strategy

Marionette will not claim to solve state-space exploration. Current scheduling
and fault choices use seeded random exploration. That is enough to enforce the
replay contract and find useful counterexamples, not enough to claim exhaustive
distributed-systems coverage.

Planned strategy layers:

- Uniform random choices first.
- Replay-visible run names, tags, and typed attributes before adding many knobs.
- Weighted fault profiles after examples reveal real needs.
- Coverage or state feedback only after there is a stable trace/event model.
- Shrinking only after failures are represented as replayable event streams.

Branch coverage alone is a weak signal for distributed simulation quality.

## Event Ordering

`World` event indexes are global and deterministic. Scenario events and
scheduler choices are emitted from one single-threaded simulation authority.
The cooperative scheduler selects from a stable task-id-ordered runnable set
using the world's seeded randomness and records each selection.

The tiebreaker must not depend on pointer addresses, hash map iteration, or OS
scheduling. A scheduler that cannot explain its next-event choice in the trace
is not deterministic enough.

## Multi-Node Authority Shape

The current Phase 2 shape is a per-node endpoint handle plus a matching
node-scoped environment:

```zig
fn nodeMain(env: mar.Env, endpoint: mar.Endpoint(Message)) !void {
    try env.record("node.send to={}", .{2});
    try endpoint.send(2, .{ .ping = {} });
}
```

Each `Endpoint(Message)` and each `sim.envForNode(node).io()` backend is bound
to one `NodeId`. Application code can send only as that node, receives only
messages addressed to that node, and opens stream sockets under that logical
process. The shared `World` remains the owner of global simulation state, but
application code should receive `Env` plus typed node-scoped endpoints, not
`World` plus a loose node id.

Rejected alternatives for now:

- Passing `*World` plus `node_id` everywhere. This is easy internally but leaks
  too much simulator authority into application code.
- Giving each node an independent world. This weakens global ordering and makes
  network partitions harder to represent correctly.

Under a partition, two endpoints differ because their node-scoped authorities
consult the world's partition state through their bound `NodeId`.

## Invariants And Liveness

Safety invariants are required for real DST. Users need to express properties
like "no two replicas disagree about committed entries" and have the simulator
check them regularly.

Planned API direction:

- Register invariants with the run, world, or scenario.
- Check cheap invariants after every event.
- Allow expensive invariants every N events and on quiescence.
- Include invariant name and event index in failure reports.

Current support is deliberately smaller: `RunOptions.checks` accepts
named `mar.Check` functions that run after the scenario body, and
`mar.runSimCase` accepts named `mar.StateCheck(State)` functions that
inspect structured scenario state. This proves the failure-report shape,
but it is not enough for serious multi-event DST yet.

Liveness is harder. The scheduler detects the concrete case where unfinished
tasks are blocked with no runnable task or pending timer. Broader progress and
fairness properties still require explicit scenario checks.

## Testing Marionette

Marionette itself must be tested as if determinism is the product.

Required test classes:

- Same seed, same scenario, byte-identical trace.
- Different seeds eventually explore different traces.
- Tidy catches banned calls and ignores comments/string literals.
- Tidy catches simple aliases to banned call paths.
- Debug and ReleaseSafe builds both pass.
- CI should run twice-and-compare on every example.

## Validation Targets

Marionette keeps several kinds of evidence deliberately separate:

- `xitdb` validation and the internal `kv_store` example exercise storage code
  through the deterministic `std.Io.File` subset and model oracles.
- The pinned `g41797/mailbox` validation exercises unmodified cooperative
  `Mutex` / `Condition` code through scheduler-backed futex waits.
- `examples/std_io_net_kv.zig` exercises production-shaped client/server code
  through the deterministic `std.Io.net` subset, including latency, loss,
  partitions, timeout, healing, and retry.
- Internal examples such as the bounded queue and replicated register are
  capability demonstrations and regression targets, not external findings.

See [Findings](findings.md) for the classification rules and current
results.

## Non-Goals

Marionette is not:

- A replacement for unit tests.
- A Jepsen alternative that runs real distributed binaries.
- A syscall interception platform.
- A general OS thread scheduler.
- A guarantee that arbitrary Zig dependencies are deterministic.
- A commitment to support every concurrency primitive in v0.1.

Scope control is part of correctness. It is better to be narrow and true than
wide and almost deterministic.

## Thread-Safety

`World` is not thread-safe. A single `World` must be driven by one OS thread at
a time. Running two independent simulations concurrently in the same process is
fine if each thread owns a different `World` and they do not share simulated
state. Cross-world coordination is outside Marionette's determinism contract.

## Stateful Runner Walkthrough

`mar.runSimCase(.{ .seed = 0x1234, .simulate = .{}, .init = init, .scenario = scenario, ... })`
chronology:

1. Freeze the seed, start time, tick size, checks, and trace settings.
2. Construct one `World`.
3. Create exactly one clock authority and one PRNG authority inside the world.
4. Call `world.simulate(config.simulate)`.
5. Invoke the user's initializer with the resulting `Sim` to build fresh app
   state.
6. Invoke the user's scenario with `*SimCase(App)`.
7. On every event, pick simulator decisions from the world's PRNG.
8. Route all time movement through the world's clock and simulator controls.
9. Record stable event data into the trace.
10. If the scenario succeeds, run configured checks in order.
11. Deinitialize app state if `App` defines `deinit`.
12. Stop on success, scenario error, check error, or deinit error.
13. Preserve a partial trace if the scenario, a check, or deinit returned an error.
14. If the first run passed, rerun the same scenario with the same seed.
15. Compare byte-identical traces.
16. Return `RunReport.passed` with one owned trace, or `RunReport.failed` with
    seed, options, event counts, failure kind, traces, error name when
    available, and check name when a check failed.

`mar.run` follows the same replay/report discipline for world-only scenarios.

The dangerous spots are scheduler choice, time advancement, raw randomness,
unordered state dumps, and host APIs. Those must stay under simulator control.
