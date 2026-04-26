# Run

`mar.run` is the Phase 0 scenario wrapper. It executes one scenario twice with
the same seed and compares the resulting traces byte-for-byte.

## Shape

```zig
const std = @import("std");
const mar = @import("marionette");

fn scenario(world: *mar.World) !void {
    try world.tick();
    _ = try world.randomIntLessThan(u64, 100);
    try world.record("scenario.done", .{});
}

test "scenario is deterministic" {
    const SmokeRunProfile = struct {
        requests: u64,
    };

    const profile: SmokeRunProfile = .{ .requests = 1 };
    const tags = [_][]const u8{ "scenario:smoke" };
    const attributes = mar.runAttributesFrom(profile);

    var report = try mar.run(std.testing.allocator, .{
        .seed = 0x1234,
        .profile_name = "smoke",
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
trace. Instead, `mar.run` captures:

- Seed and run options.
- Profile name, tags, and typed attributes.
- Failure kind.
- First trace.
- Second trace when a second run happened.
- First and second event counts.
- Error name when user code or a check returned an error.
- Check name when a named check failed.

Failure kinds:

- `scenario_error`: user scenario returned an error. The first trace is the
  partial trace through the last completed event.
- `check_failed`: a named check returned an error after the scenario body.
  The first trace is the partial trace through the check failure.
- `determinism_mismatch`: both runs completed, but their traces differed.

Panics are different from error returns. Zig's default panic path may abort
before Marionette can report a partial trace, so simulated failures should
prefer error-returning invariant checks.

`RunFailure.print()` writes one compact line to stderr. Tests should use
`RunFailure.writeSummary(writer)`, which writes the same line to a caller-owned
writer.

## Metadata

The seed is necessary but not sufficient once scenarios generate options from
that seed. Use `profile_name`, `tags`, and `attributes` to make the expanded
run shape visible:

```zig
const SmokeRunProfile = struct {
    replicas: u64,
    proposal_drop_percent: u8,
};

const profile: SmokeRunProfile = .{
    .replicas = 3,
    .proposal_drop_percent = 20,
};

const tags = [_][]const u8{ "example:replicated_register", "scenario:smoke" };
const attributes = mar.runAttributesFrom(profile);

var report = try mar.run(std.testing.allocator, .{
    .seed = 0x1234,
    .profile_name = "replicated-register-smoke",
    .tags = &tags,
    .attributes = &attributes,
}, scenario);
```

The runner records these entries before scenario code:

```text
event=1 run.profile name=replicated-register-smoke
event=2 run.tag value=example:replicated_register
event=3 run.tag value=scenario:smoke
event=4 run.attribute key=replicas value=uint:3
event=5 run.attribute key=proposal_drop_percent value=uint:20
```

Tags should be stable scalar labels. Attribute keys should be stable scalar
text, and values should use the narrow typed union Marionette exposes.
`mar.runAttributesFrom` derives attributes from a scalar-only run profile
struct using field names as keys and declaration order as output order. That
makes field names part of the exported trace contract. Use `mar.runAttribute`
directly when a stable exported key should differ from an internal field name.
Runtime behavior should read from the profile, not from derived attributes. Do
not put pointers, addresses, unordered dumps, or machine-local paths in run
metadata.

## Checks

Checks are the Phase 0 invariant hook. A world check is a named function that
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

Stateful scenarios should use `mar.runWithState`. The state initializer runs
once per replay attempt, so the second run starts from the same state as the
first:

```zig
const Model = struct {
    env: mar.AppEnv,
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

var report = try mar.runWithState(
    std.testing.allocator,
    .{ .seed = 0x1234 },
    Model,
    Model.init,
    scenario,
    &state_checks,
);
```

`init` receives the replay attempt's `World` so state can construct
world-bound simulator authorities without a later bind step. It should not
record trace events; scenario execution and checks own trace output. Stateful
scenarios and state checks receive only state; put environment authorities on
the state when they need to record or advance time.

Use `mar.runWithStateInit` when state initialization can fail but simulator
resources are owned by `World` through `world.simulate`:

```zig
const Store = struct {
    env: mar.AppEnv,
    control: mar.SimControl,

    fn init(world: *mar.World) !Store {
        const sim = try world.simulate(.{});

        return .{
            .env = sim.env,
            .control = sim.control,
        };
    }
};

var report = try mar.runWithStateInit(
    allocator,
    .{ .seed = 0x1234 },
    Store,
    Store.init,
    scenario,
    &state_checks,
);
```

Init errors are reported as scenario failures with the partial trace
preserved. Use `mar.runWithStateLifecycle` only when state owns non-world
resources that need an explicit infallible deinitializer.

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
