# Running Scenarios

`runSimCase` is the single scenario runner. It executes the same case twice and
compares byte-identical traces. Scenario and check errors are returned as data;
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

`RunReport` is either `passed` or `failed`.

Failure kinds are:

- `scenario_error`;
- `check_failed`;
- `scheduler_deadlock`;
- `scheduler_error`;
- `non_yielding`;
- `livelock`;
- `determinism_mismatch`;
- `first_run_failed`;
- `second_run_failed`.

`RunFailure.writeSummary` writes a compact replay line. The failure owns its
metadata and traces until `RunReport.deinit`.

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
twice. Long campaigns belong in the nightly seed sweep; focused unit tests
should use small counts.

## Liveness Watchdog

Cooperative tasks normally yield at simulated I/O boundaries. To contain code
that never reaches one, opt into an isolated worker process:

```zig
.watchdog = mar.WatchdogOptions{
    .stall_timeout_ns = 5 * std.time.ns_per_s,
    .run_timeout_ns = 30 * std.time.ns_per_s,
    .trace_capacity = 4 * 1024 * 1024,
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

## CLI

Run an included scenario with:

```sh
zig build run-example -- kv-store --seed 12648430 --summary
```

Use `--trace` for the full trace and `--expect-failure` for planted bugs. Run
without a valid scenario to print the current scenario list.
