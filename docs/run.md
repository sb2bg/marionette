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
    var report = try mar.run(std.testing.allocator, .{
        .seed = 0x1234,
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

## Failure Reports

Failures are not returned as bare scenario errors because that would lose the
trace. Instead, `mar.run` captures:

- Seed and run options.
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

## Checks

Checks are the Phase 0 invariant hook. A check is a named function that runs
after the scenario body and returns an error when a property is violated:

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

This is intentionally small. Future scheduler work can check invariants after
every event or on quiescence, but the current API already gives failures a
stable name and preserved trace.

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
