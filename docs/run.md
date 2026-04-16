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
- Scenario error name when user code returned an error.

Failure kinds:

- `scenario_error`: user scenario returned an error. The first trace is the
  partial trace through the last completed event.
- `determinism_mismatch`: both runs completed, but their traces differed.

Panics are different from error returns. Zig's default panic path may abort
before Marionette can report a partial trace, so simulated failures should
prefer error-returning invariant checks.

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
