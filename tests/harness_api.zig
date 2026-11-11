//! 0.10 harness API contract tests.
const std = @import("std");
const builtin = @import("builtin");
const mar = @import("marionette");

const fibers = builtin.os.tag == .macos or builtin.os.tag == .linux;

const FailFromTask = struct {
    control: mar.Control,
    after_failure: bool = false,

    fn init(sim: mar.Sim) @This() {
        return .{ .control = sim.control };
    }

    fn worker(self: *@This()) void {
        self.control.failRun(error.ReplicaDiverged);
    }

    fn other(self: *@This(), io: std.Io) void {
        std.Io.sleep(io, .fromNanoseconds(10), .awake) catch return;
        // The scheduler stops at the failure: this never runs.
        self.after_failure = true;
    }

    fn scenario(case: *mar.SimCase(@This())) !void {
        const io = case.env().io();
        var later = try std.Io.concurrent(io, other, .{ &case.app, io });
        var failing = try std.Io.concurrent(io, worker, .{&case.app});
        failing.await(io);
        later.await(io);
    }
};

test "harness: failRun from a task fails the run with a replayable report" {
    if (!fibers) return error.SkipZigTest;
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = FailFromTask.init,
        .scenario = FailFromTask.scenario,
    });
    defer report.deinit();
    try std.testing.expect(report == .failed);
    try std.testing.expectEqual(mar.RunFailureKind.task_failed, report.failed.kind);
    try std.testing.expectEqualStrings("ReplicaDiverged", report.failed.error_name.?);
    try mar.expectTraceContains(report.failed.first_trace, "run.task_failure task=1 error=ReplicaDiverged");
    try std.testing.expect(std.mem.indexOf(u8, report.failed.first_trace, "scheduler.timeout") == null);

    const identity: mar.ReplayIdentity = .{ .build = "harness", .sut = "fail-run" };
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replay = try mar.replaySimCase(.{ .allocator = std.testing.allocator, .init = FailFromTask.init, .scenario = FailFromTask.scenario }, &capsule, identity);
    defer replay.deinit();
    try std.testing.expectEqual(mar.RunFailureKind.task_failed, replay.failed.kind);
}

const FailFromScenario = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }

    fn scenario(case: *mar.SimCase(@This())) !void {
        case.control().failRun(error.OracleRejected);
    }
};

test "harness: failRun from the scenario reports task_failed" {
    try mar.expectSimFailure(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = FailFromScenario.init,
        .scenario = FailFromScenario.scenario,
        .failure = mar.FailureExpectation{ .kind = .task_failed, .error_name = "OracleRejected" },
    });
}

const LineSink = struct {
    lines: [4][64]u8 = undefined,
    lens: [4]usize = @splat(0),
    count: usize = 0,

    fn write(ptr: *anyopaque, line: []const u8) void {
        const self: *LineSink = @ptrCast(@alignCast(ptr));
        if (self.count == self.lines.len) return;
        const len = @min(line.len, 64);
        @memcpy(self.lines[self.count][0..len], line[0..len]);
        self.lens[self.count] = len;
        self.count += 1;
    }

    fn line(self: *const LineSink, index: usize) []const u8 {
        return self.lines[index][0..self.lens[index]];
    }
};

test "harness: a production recorder hands formatted lines to its sink" {
    var sink: LineSink = .{};
    const recorder = mar.Recorder.fromSink(.{ .ptr = &sink, .write = LineSink.write });
    recorder.record("app.commit id={}", .{7});
    _ = recorder.event("app.persist", &.{ mar.traceField("path", .{ .text = "wal log" }), mar.traceField("len", .{ .uint = 4 }) }, null);
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    try std.testing.expectEqualStrings("app.commit id=7", sink.line(0));
    try std.testing.expectEqualStrings("app.persist path=wal%20log len=4", sink.line(1));
}

const BadRecording = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }

    fn scenario(case: *mar.SimCase(@This())) !void {
        // Spaces are not a valid event name: the call returns normally and
        // the runner reports the failure at its next boundary.
        case.env().record("not a valid event", .{});
        case.env().record("app.after value=1", .{});
    }
};

test "harness: a failed app recording fails the run at the next boundary" {
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = BadRecording.init,
        .scenario = BadRecording.scenario,
    });
    defer report.deinit();
    try std.testing.expectEqual(mar.RunFailureKind.recording_failed, report.failed.kind);
    try std.testing.expectEqualStrings("InvalidTracePayload", report.failed.error_name.?);
    try mar.expectTraceContains(report.failed.first_trace, "app.after value=1");
}
