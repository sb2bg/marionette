# Decision Tapes And Replay Capsules

Seeds and seed schedules explore executions. A decision tape records the actual
choices. A replay capsule persists that tape together with the information
needed to verify an execution later.

## Compatibility Contract

Seed schedules reset the PRNG at `(sim_time_ns, microstep)` positions. They are
same-build controls: adding an earlier draw can move later positions. Making a
seed schedule durable would require recording the choices it produced, which
is the tape's job.

Capsules are durable **for a pinned build and workload**, not promises that an
old execution survives arbitrary application or simulator changes. They retain
build/SUT identities, Zig version, target, optimization mode, disk semantic
version, initial seed and cutovers, runner options, simulation options, trace,
error/check identity, and exact decisions. Replay rejects incompatible
identities, unsupported versions, malformed traces/decisions, and incomplete
tapes. It then checks every choice boundary and the complete trace and outcome.

The caller must supply meaningful `build` and `sut` identities, retain the
matching executable/source/dependencies, and provide the matching initializer,
scenario, checks, and application input. Include the input/workload identity in
`sut`; capsules do not serialize arbitrary application state or closures.
Changing code requires a new identity and exploration, not relabeling the old
artifact. Cross-version migration and reduction are future work.

## Entry Contract

Each `Decision` contains a semantic `site_id`, simulated `logical_time_ns`, a
zero-based `microstep` at that timestamp, the preceding trace event, typed
alternatives, and a selected value. Alternatives are any `u64`, boolean,
bounded unsigned integer, or an exact byte count. Byte decisions own the
complete byte buffer; their scalar selection is a deterministic digest.

Site IDs use lowercase ASCII words, digits, and `_`, separated by single `.`
characters. The decision contract and capsule envelope are independently
versioned at version 1. The execution payload is shared with watchdog transport.

Scheduler, network, disk, allocation, automatic process events, named world
choices, legacy traced `World.random*` calls, and `std.Io` application random
bytes participate. Workload/BUGGIFY choices participate when they use those
controlled authorities. Ambient host randomness is outside the contract.

## Runner And Ownership

`runSimCase` records the first execution, exact-replays its tape on the second,
and compares traces and failure identities. The first mismatch produces
`RunFailureKind.replay_diverged` with an owned `replay_divergence`, identifying
the tape index and expected/actual boundaries. Mismatches survive rollback and
remain fatal even if application code catches the immediate error.

`RunResult` and `RunFailure` own the first `decision_tape`; `takeDecisionTape`
transfers it. Otherwise call `RunReport.deinit` to release all owned storage.

Completed watchdog workers publish the same owned execution payload and use
exact replay. Killed or prematurely exited workers retain only a trace prefix,
set `tape_complete = false`, and use same-seed replay. Timeouts require matching
failure identities and compatible trace prefixes; worker crashes require exact
traces. Incomplete reports cannot become capsules.

## Save And Replay

```zig
const identity: mar.ReplayIdentity = .{
    .build = "simulator-and-application-build-digest",
    .sut = "sut-revision-and-workload-input-digest",
};
const simulate: mar.World.SimulateOptions = .{};
var report = try mar.runSimCase(.{
    .allocator = allocator,
    .simulate = simulate,
    .init = App.init,
    .scenario = App.scenario,
});
defer report.deinit();

const bytes = try mar.ReplayCapsule.encode(allocator, &report, identity);
defer allocator.free(bytes);
// Persist bytes using the harness's caller-provided host std.Io.
// The report retains the simulation options actually used.

var capsule = try mar.ReplayCapsule.decode(allocator, bytes);
defer capsule.deinit();
var replayed = try mar.replaySimCase(.{
    .allocator = allocator,
    .init = App.init,
    .scenario = App.scenario,
    // Supply the original checks too, when present.
}, &capsule, identity);
defer replayed.deinit();
```

Encoding supports passing runs and reproducible failures. It rejects divergent
reports (`UnreproducibleRun`) and incomplete tapes (`IncompleteDecisionTape`).
Nonfinite float metadata is encoded as tagged JSON strings (`inf`, `-inf`,
`nan`) and round-trips alongside finite values. The codec never performs host I/O. `decode` owns its parsed storage, while the
returned replay report owns its own storage and outlives the capsule.

## Direct World Use

```zig
var recording = try mar.World.init(allocator, .{ .seed = 1234 });
defer recording.deinit();
_ = try recording.chooseIntLessThan("scheduler.select", usize, runnable_count);
var tape = try recording.cloneDecisionTape(allocator);
defer tape.deinit();

var replaying = try mar.World.init(allocator, .{
    .seed = 9999,
    .decisions = .{ .replay = tape.entries },
});
defer replaying.deinit();
_ = try replaying.chooseIntLessThan("scheduler.select", usize, runnable_count);
try replaying.finishDecisionReplay();
```

World choices stage PRNG, cutover, trace, and tape changes transactionally. An
allocation failure retries the same value and microstep. Fatal replay diagnostics
are deliberately outside that rollback boundary. Direct tape replay can override
a different generated seed value; full capsule replay also verifies configuration
and trace, and therefore retains the original seed and schedule.
