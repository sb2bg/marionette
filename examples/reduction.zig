//! Reduce an idempotency failure into a replayable pair of essential actions.
const std = @import("std");
const mar = @import("marionette");

const Service = struct {
    recorder: mar.Recorder,
    applied: u32 = 0,
    fn apply(self: *@This()) !void {
        var operation = try self.recorder.beginOperation("apply.request", null);
        // Planted bug: the repeated request is applied a second time.
        self.applied += 1;
        _ = try operation.event("service.applied", &.{mar.traceField("count", .{ .uint = self.applied })});
        try operation.end();
    }
};
const Case = mar.SimCase(Service);
fn init(sim: mar.Sim) Service {
    return .{ .recorder = sim.env.recorder() };
}
fn telemetry(case: *Case) !void {
    try case.env().record("service.telemetry", .{});
}
fn apply(case: *Case) !void {
    try case.app.apply();
}
fn scenario(case: *Case) !void {
    try case.action("telemetry", telemetry);
    try case.action("request", apply);
    try case.action("duplicate", apply);
    try case.checkpoint("after.retry");
}
fn invariant(case: *const Case) !void {
    if (case.app.applied > 1) return error.DuplicateApplied;
}
const checks = [_]mar.StateCheck(Case){
    .{ .name = "service.at_most_once", .phase = .checkpoint, .check = invariant },
};

pub fn run(allocator: std.mem.Allocator, seed: u64) !mar.ReductionResult {
    return mar.reduceSimCase(.{
        .allocator = allocator,
        .seed = seed,
        .simulate = mar.World.SimulateOptions{},
        .init = init,
        .scenario = scenario,
        .checks = &checks,
    }, .{});
}

test "reduction example retains only the request and its duplicate" {
    var result = try run(std.testing.allocator, 1234);
    defer result.deinit();
    try std.testing.expect(result.one_minimal);
    try std.testing.expectEqual(@as(usize, 2), result.remaining_groups);
    try std.testing.expect(std.mem.indexOf(u8, result.report().failed.first_trace, "service.telemetry") == null);
}
