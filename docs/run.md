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

## Outcomes

`RunReport` is either `passed` or `failed`.

Failure kinds are:

- `scenario_error`;
- `check_failed`;
- `determinism_mismatch`;
- `first_run_failed`;
- `second_run_failed`.

`RunFailure.writeSummary` writes a compact replay line. The failure owns its
metadata and traces until `RunReport.deinit`.

## Test Helpers

Use `expectSimPass` for normal cases and `expectSimFailure` for planted bugs.
Use `runSimCase` directly when a test must assert the exact failure kind, error,
check name, or trace.

`expectSimFuzz` requires a nonzero `seeds` field. Each derived seed is replayed
twice. Long campaigns belong in the nightly seed sweep; focused unit tests
should use small counts.

## CLI

Run an included scenario with:

```sh
zig build run-example -- kv-store --seed 12648430 --summary
```

Use `--trace` for the full trace and `--expect-failure` for planted bugs. Run
without a valid scenario to print the current scenario list.
