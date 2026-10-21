# Running Scenarios

`runSimCase` is the single scenario runner. It records a semantic decision tape
during the first execution, exact-replays it during the second, and compares
byte-identical traces. Scenario and check errors are returned as data;
allocation or trace-infrastructure errors remain Zig errors.

## Define A Case

```zig
const Case = mar.SimCase(Service);

fn init(sim: mar.Sim) !Service {
    return Service.init(sim.env.io(), sim.env.recorder());
}

fn scenario(case: *Case) !void {
    try case.app.request();
    try case.control().network.partition(&.{0}, &.{1});
    try case.control().tick();
}

fn safe(case: *const Case) !void {
    if (!case.app.safe()) return error.InvariantBroken;
}
```

Run it with typed simulation options:

```zig
const checks = [_]mar.StateCheck(Case){
    .{ .name = "service remains safe", .check = safe },
};

var report = try mar.runSimCase(.{
    .allocator = allocator,
    .seed = seed,
    .name = "partition",
    .simulate = mar.World.SimulateOptions{
        .network = .{ .nodes = 2 },
    },
    .init = init,
    .scenario = scenario,
    .checks = &checks,
});
defer report.deinit();
```

The runner owns world and application cleanup. If the app type defines
`deinit`, it runs before each world is destroyed and remains part of replay
comparison.

## Property Lifecycle

`StateCheck.name` is the stable property ID used in `check_name` failure reports,
expectations, and replay capsules. Choose a semantic name such as
`service.safety`; changing the name changes failure identity. Empty or duplicate
names return `error.InvalidStateChecks` before initialization or watchdog
isolation, including when replaying a capsule.

Set `phase` to choose a deterministic lifecycle boundary:

```zig
const checks = [_]mar.StateCheck(Case){
    .{ .name = "service.initial", .phase = .after_init, .check = initial },
    .{ .name = "service.safety", .phase = .both, .check = safe },
    .{ .name = "service.complete", .check = complete },
};
```

`.after_init` runs after successful initialization and before the scenario.
`.after_scenario` is the default and runs after a successful scenario.
`.both` runs at each lifecycle boundary. `.checkpoint` runs only at explicit
`case.checkpoint("semantic.id")` calls; `.always` runs at all three kinds of
boundary. Within a boundary, checks run in declaration order. The first failure stops later checks and the scenario if it has not
started. Successfully initialized application state is cleaned up exactly
once per execution, including failed checks; cleanup remains part of replay.
Initialization and scenario errors skip subsequent boundaries. Scheduler
failures detected during a check take precedence over its returned error.

Before invoking a check, the runner records `run.check` with its ID and phase.
This identifies the boundary even if the callback never returns. Checks should
inspect state without advancing the simulation or mutating the application;
recording diagnostics is supported. These boundaries do not drain tasks or
imply quiescence. They are harness call boundaries, not automatic checks after
every scheduler step. See [Reduction and Explanation](reduction-and-explanation.md) for explicit
checkpoints, action groups, reduction, artifacts, and managed process cleanup.

Capsules retain failure IDs and lifecycle trace events; callbacks and their
phase configuration remain part of the pinned harness build. Supply the same
`checks` to `replaySimCase`.

## Seed Schedules

Use `seed_schedule` to reset the deterministic random stream at exact traced
random-call boundaries without changing simulated time:

```zig
const schedule = [_]mar.SeedCutover{
    .{
        .at = .{ .sim_time_ns = 10, .microstep = 0 },
        .seed = 0xA11CE,
    },
    .{
        .at = .{ .sim_time_ns = 10, .microstep = 3 },
        .seed = 0xB0B,
    },
};

var report = try mar.runSimCase(.{
    .allocator = allocator,
    .seed = 0xC0FFEE,
    .seed_schedule = @as(mar.SeedSchedule, &schedule),
    // simulate, init, and scenario omitted
});
defer report.deinit();
```

Cutovers must be strictly increasing by `(sim_time_ns, microstep)` or the
runner returns `error.InvalidSeedSchedule`. A microstep counts one successfully
traced random API call at that simulated timestamp, including one
`Io.random` call regardless of its buffer length. If execution passes a point
without drawing randomness there, the cutover takes effect before the next
later draw. Schedules are reproduced in traces and failure summaries.

This is a same-build positional control, not a durable replay format. Code that
adds or removes an earlier random call can shift later microsteps.

## Outcomes

Set `.check_resources = true` in the runner configuration to check simulated
handles after a successful scenario, named checks, and `App.deinit`, before
world teardown. The default is `false`, allowing scenarios to finish with
services running. Leaks produce `resource_leak` with error name `ResourceLeak`.
Existing scenario/check failures take precedence. This also works with the
watchdog and expectation/fuzz helpers.

For an explicit checkpoint, call `try sim.control.checkResources()` after
application cleanup. It checks all processes, records diagnostics, and returns
`error.ResourceLeak` without closing resources. An error propagated from a
scenario or named check keeps its usual `scenario_error` or `check_failed`
classification.

Checks cover live simulated files, directories, listeners, and client/accepted
sockets. Pending accepts belong to their listener; closed sockets awaiting
internal retirement are excluded. Process kill, disk crash, and the disk
model's deletion semantics retire handles, so those no longer appear. This
checks current modeled ownership, not every historical missing close. Host
descriptors, tasks/futures, memory, typed endpoints, and arbitrary user
resources are outside this check. Allocation-site stacks are not captured.

`RunReport` is either `passed` or `failed`.

Failure kinds are:

- `resource_leak`;
- `scenario_error`;
- `check_failed`;
- `scheduler_deadlock`;
- `scheduler_error`;
- `non_yielding`;
- `livelock`;
- `worker_crashed`;
- `step_budget_exceeded`;
- `replay_diverged`;
- `determinism_mismatch`;
- `first_run_failed`;
- `second_run_failed`.

`RunFailure.writeSummary` writes a compact replay line. A passed or failed
report owns the first execution's decision tape; a replay divergence also owns
the expected and actual decision boundaries. `takeDecisionTape` transfers tape
ownership. All remaining metadata, traces, and tape storage live until
`RunReport.deinit`.

See [Decision Tapes](decision-tapes.md) for entry semantics and direct replay.

## Test Helpers

Use `expectSimPass` for normal cases and `expectSimFailure` for planted bugs.
An optional `failure` field can require any combination of kind, error name,
and check name:

```zig
try mar.expectSimFailure(.{
    // allocator, simulation, initializer, and scenario omitted
    .failure = mar.FailureExpectation{
        .kind = .check_failed,
        .error_name = "InvariantBroken",
        .check_name = "service remains safe",
    },
});
```

Omitted constraints accept any value. A mismatch returns
`error.UnexpectedRunFailure`. Use `runSimCase` directly when a test must inspect
the full failure or trace.

`expectSimFuzz` requires a nonzero `seeds` field. Each derived seed is replayed
twice. It stops at the first failure; use [`runCampaign`](campaigns.md) to keep
going, group failures, and retain evidence. Focused unit tests should use small
counts.

## Fault Coverage

A passing run only shows fault tolerance if the faults actually did something.
A crash with no pending writes, or a partition that carried no traffic, passes
the same invariants as a run with no faults at all. `faultCoverage(trace)`
counts the injected faults in a trace without allocating:

```zig
var report = try mar.runSimCase(config);
defer report.deinit();
const coverage = try mar.faultCoverage(report.passed.trace);
try std.testing.expect(coverage.crash_lost_writes + coverage.crash_torn_writes > 0);
```

`FaultCoverage` counts disk crashes and partitions as injections, and the
effects an application could observe: writes a crash lost, tore, or reordered;
lost metadata; disk read and write errors; corrupt reads; network drops;
process kills; and injected allocation failures. `fired()` is true when any
effect was counted. A disk crash restarts every process, so its own kills are
not counted separately: a crash with nothing pending is a clean restart and
does not make `fired()` true. `summarize` reports the same counts, and the
`--summary` output ends with a `trace.faults` line. Campaigns total coverage
across cases; see [Campaigns](campaigns.md#fault-coverage).

## Crash-Point Sweeps

Durable code is usually correct or wrong at a specific crash point: after the
data is synced but before the directory entry is, for example. A sweep runs the
scenario once per disk operation, crashing before that operation:

```zig
fn scenario(case: *Case) !void {
    // ...setup...
    try case.armCrashPoint();
    const committed = commit(case.env());
    _ = try case.finishCrashPoint(); // true when the armed crash fired
    committed catch |err| if (err != error.DiskCrashed) return err;
    // ...restart if crashed, recover, and check...
}

try mar.expectCrashPointsPass(config, .{});
```

`armCrashPoint` arms `crashAfterOps(k)` for the sweep's current point `k`, and
does nothing in an ordinary run, so the same scenario works in both.
`finishCrashPoint` cancels a crash that has not fired, so recovery code after it
runs normally; the runner also cancels it when the scenario returns, so checks
never run with a crash armed. `sweepCrashPoints(config, CrashSweepOptions)`
tries points 0, 1, 2, and so on until one where the armed crash never fired,
and returns the first failing report instead of stopping at an error. Each point
is an ordinary recorded and exact-replayed run whose point is the
`marionette.crash_point` run attribute, so a failing point's capsule replays
that point. A scenario that never arms returns `CrashPointNotArmed`, and
`max_points` (1024 by default) bounds a workload that never finishes.

## Step Budget

A task that keeps sleeping, waking a peer, or retrying never deadlocks, so
without a bound it simply runs forever. Set a deterministic budget on the
simulation to turn that into an ordinary failure:

```zig
.simulate = mar.World.SimulateOptions{ .step_budget = 100_000 },
```

One step is a task dispatch or a scheduler-driven clock advance, so loops that
only sleep, and tasks that only wake each other, both count. When the budget
runs out the scheduler records
`scheduler.step_budget_exceeded budget=<u64> ready=<u64> blocked=<u64>` and the
run fails as `step_budget_exceeded` with error name `StepBudgetExceeded`. No
task runs past the budget, including during application cleanup.

The count depends only on the decisions, so both executions stop at the same
step. Unlike a watchdog `livelock`, the decision tape is complete: the failure
encodes as a replay capsule, replays exactly, and can be reduced. Choose a
budget well above what passing runs use; a passing run's trace does not depend
on the budget. Code that never yields takes no steps, so it still needs the
watchdog below. An unset budget (the default) is omitted from serialized
options, so earlier artifacts keep their bytes.

## Liveness Watchdog

Cooperative tasks normally yield at simulated I/O boundaries. To contain code
that never reaches one, opt into an isolated worker process:

```zig
.watchdog = mar.WatchdogOptions{
    .stall_timeout_ns = 5 * std.time.ns_per_s,
    .run_timeout_ns = 30 * std.time.ns_per_s,
    .trace_capacity = 4 * 1024 * 1024,
    .result_capacity = 16 * 1024 * 1024,
},
```

The stall bound classifies worker code with no observed progress as
`non_yielding`, whether it runs directly in the scenario (`task=main`) or in a
cooperative task. The total-time and partial-trace bounds classify continuing
activity as `livelock`. Completed trace events are copied from shared memory
and a final `watchdog.non_yielding` or `watchdog.livelock` event identifies the
classification.

The watchdog is available on Linux, macOS, FreeBSD, NetBSD, OpenBSD,
DragonFly BSD, and illumos. Its deadlines use host monotonic time and do not
enter simulated time or deterministic choices. It uses `fork`, so enable it
from a single-threaded harness process before starting unrelated host threads.
Without `.watchdog`, execution and allocator behavior are unchanged.
Completed workers publish their full decision tape and use exact replay.
Terminated workers set `tape_complete = false` and retain same-seed trace-prefix
replay; an unexpected worker exit is `worker_crashed` and must reproduce its
exact trace. Incomplete tapes cannot be encoded as replay capsules. The
`result_capacity` bounds the encoded completed result, including decisions;
overflow returns `WatchdogTraceTooLarge`. See
[Decision Tapes And Replay Capsules](decision-tapes.md) for persistent replay.

## CLI

Run an included scenario with:

```sh
zig build run-example -- kv-store --seed 12648430 --summary
```

Use `--trace` for the full trace and `--expect-failure` for planted bugs. Run
without a valid scenario to print the current scenario list.
