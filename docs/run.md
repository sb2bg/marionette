# Run

`mar.runCase` is the primary stateful scenario wrapper. It initializes a fresh
state value for each replay attempt, executes the scenario twice with the same
seed, runs named checks, and compares the resulting traces byte-for-byte.

`mar.run` remains the lower-level world-only wrapper for scenarios that do not
need structured state.

## World-Only Shape

```zig
const std = @import("std");
const mar = @import("marionette");

fn scenario(world: *mar.World) !void {
    try world.tick();
    _ = try world.randomIntLessThan(u64, 100);
    try world.record("scenario.done", .{});
}

test "scenario is deterministic" {
    const tags = [_][]const u8{ "scenario:smoke" };
    const attributes = [_]mar.RunAttribute{
        mar.runAttribute("requests", @as(u64, 1)),
    };

    var report = try mar.run(std.testing.allocator, .{
        .seed = 0x1234,
        .name = "smoke",
        .tags = &tags,
        .attributes = &attributes,
        .checks = &.{.{ .name = "trace exists", .check = traceExists }},
    }, scenario);
    defer report.deinit();

    switch (report) {
        .passed => |passed| {
            try std.testing.expect(passed.trace.len > 0);
        },
        .failed => |failure| {
            failure.print();
            return error.ScenarioFailed;
        },
    }
}

fn traceExists(world: *mar.World) !void {
    if (world.traceBytes().len == 0) return error.EmptyTrace;
}
```

`mar.run` returns `mar.RunReport`:

- `.passed` contains one owned trace from the first successful run.
- `.failed` contains a data-bearing failure report.

Call `report.deinit()` when done.

## Example Runner

The repository includes a small runner for replaying built-in examples from a
seed:

```sh
zig build run-example -- replicated-register --seed 12648430 --summary
zig build run-example -- replicated-register --seed 12648430 --trace
zig build run-example -- retry-queue-bug --seed 12648430 --expect-failure
```

`--summary` renders `mar.summarize` output for passing traces. `--trace` prints
the raw trace. Known-bug scenarios return nonzero when they fail unless
`--expect-failure` is supplied.

## Failure Reports

Failures are not returned as bare scenario errors because that would lose the
trace. Instead, the runner captures:

- Seed and run options.
- Run name, tags, and typed attributes.
- Failure kind.
- First trace.
- Second trace when a second run happened.
- First and second event counts.
- Error name when user code or a check returned an error.
- Check name when a named check failed.

Failure kinds:

- `scenario_error`: user scenario returned an error in both runs with an
  identical trace. The first trace is the partial trace through the last
  completed event; the failure is verified replayable.
- `check_failed`: a named check returned an error after the scenario body,
  identically in both runs. The first trace is the partial trace through the
  check failure.
- `determinism_mismatch`: the runs diverged. Either both passed with
  different traces, or both failed but not byte-identically. When both runs
  failed, `error`/`check` describe the first run and
  `second_error`/`second_check` describe the second.
- `second_run_failed`: the first run passed but the second failed with the
  same seed. A determinism leak surfaced through an error; `error` (and
  `check`, if set) describe the second run's failure.
- `first_run_failed`: the first run failed but the second passed with the
  same seed. A determinism leak: the failure did not reproduce. `error` (and
  `check`, if set) describe the first run's failure, and the second trace is
  the passing run's trace.

The runner always executes both runs, even when the first fails, so every
reported `scenario_error` or `check_failed` has already been replayed once.

Panics are different from error returns. Zig's default panic path may abort
before Marionette can report a partial trace, so simulated failures should
prefer error-returning invariant checks.

`RunFailure.print()` writes one compact line to stderr. Tests should use
`RunFailure.writeSummary(writer)`, which writes the same line to a caller-owned
writer.

## Metadata

The seed is necessary but not sufficient once scenarios generate options from
that seed. Use a run name, tags, and attributes to make the expanded run shape
visible. Both `mar.runCase` and the lower-level `mar.run` options use `.name`:

```zig
const tags = [_][]const u8{ "example:replicated_register", "scenario:smoke" };
const attributes = [_]mar.RunAttribute{
    mar.runAttribute("replicas", @as(u64, 3)),
    mar.runAttribute("packet_loss_percent", @as(u8, 20)),
};

var report = try mar.run(std.testing.allocator, .{
    .seed = 0x1234,
    .name = "replicated-register-smoke",
    .tags = &tags,
    .attributes = &attributes,
}, scenario);
```

The runner records these entries before scenario code:

```text
event=1 run.name value=replicated-register-smoke
event=2 run.tag value=example:replicated_register
event=3 run.tag value=scenario:smoke
event=4 run.attribute key=replicas value=uint:3
event=5 run.attribute key=packet_loss_percent value=uint:20
```

Tags should be stable scalar labels. Attribute keys should be stable scalar
text, and values should use the narrow typed union Marionette exposes.
Use `mar.runAttribute` to build attributes; keys are written explicitly so
exported trace keys never silently track internal field renames. Runtime
behavior should read from the config, not from derived attributes. Do not put pointers,
addresses, unordered dumps, or machine-local paths in run metadata.

## Checks

Checks are the post-scenario invariant hook. A world check is a named function that
runs after the scenario body and returns an error when a property is violated:

```zig
fn noBadState(world: *mar.World) !void {
    if (std.mem.indexOf(u8, world.traceBytes(), "bad_state") != null) {
        return error.BadState;
    }
}

const checks = [_]mar.Check{
    .{ .name = "no bad state", .check = noBadState },
};

var report = try mar.run(std.testing.allocator, .{
    .seed = 0x1234,
    .checks = &checks,
}, scenario);
```

Stateful scenarios should usually use `mar.runCase`. The state initializer
runs once per replay attempt, so the second run starts from the same state as
the first:

```zig
const Model = struct {
    env: mar.Env,
    committed: bool = false,

    fn init(world: *mar.World) Model {
        const sim = world.simulate(.{}) catch unreachable;
        return .{ .env = sim.env };
    }
};

fn scenario(model: *Model) !void {
    model.committed = true;
    try model.env.record("model.commit", .{});
}

fn committed(model: *const Model) !void {
    if (!model.committed) return error.NotCommitted;
    try model.env.record("model.check committed=true", .{});
}

const state_checks = [_]mar.StateCheck(Model){
    .{ .name = "committed", .check = committed },
};

var report = try mar.runCase(.{
    .allocator = std.testing.allocator,
    .seed = 0x1234,
    .name = "model-smoke",
    .init = Model.init,
    .scenario = scenario,
    .checks = &state_checks,
});
```

`init` receives the replay attempt's `World` so state can construct
world-bound simulator authorities without a later bind step. It should not
record trace events; scenario execution and checks own trace output. Stateful
scenarios and state checks receive only state; put environment authorities on
the state when they need to record or advance time.

Use `mar.expectPass` when the test only needs to fail loudly on a bad run:

```zig
const Store = struct {
    env: mar.Env,
    control: mar.Control,

    fn init(world: *mar.World) !Store {
        const sim = try world.simulate(.{});

        return .{
            .env = sim.env,
            .control = sim.control,
        };
    }
};

try mar.expectPass(.{
    .allocator = std.testing.allocator,
    .seed = 0x1234,
    .init = Store.init,
    .scenario = scenario,
    .checks = &state_checks,
});
```

Use `mar.expectFuzz` to run many deterministic seeds and report the failing
seed if one fails:

```zig
try mar.expectFuzz(.{
    .allocator = std.testing.allocator,
    .seed = 0x1234,
    .seeds = 1000,
    .init = Store.init,
    .scenario = scenario,
    .checks = &state_checks,
});
```

Use `mar.expectFailure` when proving a checker catches a known-buggy scenario.
If state owns non-world resources, pass an explicit infallible deinitializer:

```zig
var report = try mar.runCase(.{
    .allocator = std.testing.allocator,
    .seed = 0x1234,
    .init = Model.init,
    .deinit = Model.deinit,
    .scenario = scenario,
    .checks = &state_checks,
});
```

This is intentionally small. Future scheduler work can check invariants after
every event or on quiescence, but the current API already gives failures a
stable name, preserved trace, and direct access to structured scenario state.

## Ownership

Successful traces are owned by `RunReport`. To return a trace from a helper,
use `takeTrace()`:

```zig
var report = try mar.run(allocator, .{ .seed = seed }, scenario);
defer report.deinit();

switch (report) {
    .passed => |*passed| return passed.takeTrace(),
    .failed => |failure| {
        failure.print();
        return error.ScenarioFailed;
    },
}
```
