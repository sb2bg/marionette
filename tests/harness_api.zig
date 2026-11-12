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

    fn write(ptr: *anyopaque, bytes: []const u8) void {
        const self: *LineSink = @ptrCast(@alignCast(ptr));
        if (self.count == self.lines.len) return;
        const len = @min(bytes.len, 64);
        @memcpy(self.lines[self.count][0..len], bytes[0..len]);
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
        // An empty value is invalid even escaped: the call returns normally and
        // the runner reports the failure at its next boundary.
        case.env().record("app.note value={s}", .{""});
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

const Helpers = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }

    fn scenario(case: *mar.SimCase(@This())) !void {
        const control = case.control();
        const flip = try control.chooseBool("harness.flip");
        const pick = try control.chooseIntLessThan("harness.pick", u8, 4);
        var bytes: [4]u8 = undefined;
        try control.randomBytes(&bytes);
        control.record("harness.drawn flip={} pick={} now_ns={}", .{ flip, pick, control.now() });
        try std.testing.expect(std.mem.indexOf(u8, control.traceBytes(), "harness.drawn") != null);
        // The single process-control surface.
        try control.process.kill(0);
        try control.process.restart(0);
    }
};

test "harness: Control carries decisions, recording, time, and process control" {
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = Helpers.init,
        .scenario = Helpers.scenario,
    });
    defer report.deinit();
    try std.testing.expect(report == .passed);
    try mar.expectTraceContains(report.passed.trace, "harness.drawn flip=");
    try mar.expectTraceContains(report.passed.trace, "process.kill node=0");
}

test "harness: grouped namespaces name the same types as the flat exports" {
    try std.testing.expect(mar.net.Fault == mar.NetworkFault);
    try std.testing.expect(mar.replay.Capsule == mar.ReplayCapsule);
    try std.testing.expect(mar.disk.Control == mar.DiskControl);
    try std.testing.expect(mar.process.Control == mar.ProcessControl);
    try std.testing.expect(mar.trace.Recorder == mar.Recorder);
}

const Counter = struct {
    value: u8 = 0,

    fn init(_: mar.Sim) @This() {
        return .{};
    }

    fn scenario(case: *mar.SimCase(@This())) !void {
        case.app.value = try case.control().chooseIntLessThan("counter.value", u8, 8);
        case.control().record("counter.value value={}", .{case.app.value});
    }

    fn belowSix(case: *const mar.SimCase(@This())) !void {
        if (case.app.value >= 6) return error.CounterTooLarge;
    }

    const checks = [_]mar.StateCheck(mar.SimCase(@This())){
        .{ .name = "counter.below_six", .check = belowSix },
    };
};

const CounterHarness = mar.Harness(.{
    .init = Counter.init,
    .scenario = Counter.scenario,
    .checks = &Counter.checks,
    .name = "counter",
});

test "harness: one typed harness runs, replays, and reduces with the same checks" {
    var seed: u64 = 0;
    var failing: ?mar.RunReport = null;
    while (seed < 64) : (seed += 1) {
        var report = try CounterHarness.run(std.testing.allocator, .{ .seed = seed });
        if (report == .failed) {
            failing = report;
            break;
        }
        report.deinit();
    }
    var report = failing orelse return error.NoFailingSeed;
    defer report.deinit();
    try std.testing.expectEqualStrings("counter.below_six", report.failed.check_name.?);
    try mar.expectTraceContains(report.failed.first_trace, "run.name value=counter");

    const identity: mar.ReplayIdentity = .{ .build = "harness", .sut = "counter" };
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replayed = try CounterHarness.replay(std.testing.allocator, &capsule, identity);
    defer replayed.deinit();
    try std.testing.expectEqualStrings("counter.below_six", replayed.failed.check_name.?);

    try CounterHarness.expectFailure(std.testing.allocator, .{ .seed = seed }, .{ .kind = .check_failed, .check_name = "counter.below_six" });
    var reduced = try CounterHarness.reduce(std.testing.allocator, .{ .seed = seed }, .{ .max_attempts = 4 });
    defer reduced.deinit();
}

const repro_options = @import("marionette_repro");

test "harness: build reproduction options name the build and an optional rerun" {
    const identity = mar.repro.identity(repro_options, "counter");
    try std.testing.expect(identity.build.len > 0);
    try std.testing.expectEqualStrings("counter", identity.sut);
    // A failing fuzz prints the seed; `-Dmarionette-seed` reruns exactly it.
    try CounterHarness.fuzz(std.testing.allocator, .{ .seed = 3 }, .{ .seeds = 1, .rerun = mar.repro.rerunSeed(repro_options) orelse passingSeed() });
}

fn passingSeed() u64 {
    var seed: u64 = 0;
    while (true) : (seed += 1) {
        var report = CounterHarness.run(std.testing.allocator, .{ .seed = seed }) catch unreachable;
        defer report.deinit();
        if (report == .passed) return seed;
    }
}

test "harness: the cli reruns, replays, and reduces without code changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var seed: u64 = 0;
    var report = while (true) : (seed += 1) {
        var candidate = try CounterHarness.run(std.testing.allocator, .{ .seed = seed });
        if (candidate == .failed) break candidate;
        candidate.deinit();
    };
    defer report.deinit();
    const identity = mar.repro.identity(repro_options, "counter");
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "replay.json", .data = bytes });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "replay.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var seed_text: [24]u8 = undefined;
    const seed_arg = try std.fmt.bufPrint(&seed_text, "{}", .{seed});
    try std.testing.expectEqual(@as(u8, 1), try mar.cli.run(CounterHarness, std.testing.allocator, std.testing.io, &.{ "rerun", seed_arg }, identity, &output.writer));
    try std.testing.expectEqual(@as(u8, 0), try mar.cli.run(CounterHarness, std.testing.allocator, std.testing.io, &.{ "replay", path }, identity, &output.writer));
    try std.testing.expectEqual(@as(u8, 0), try mar.cli.run(CounterHarness, std.testing.allocator, std.testing.io, &.{ "reduce", path, "--attempts", "4" }, identity, &output.writer));
    try std.testing.expectEqual(@as(u8, 2), try mar.cli.run(CounterHarness, std.testing.allocator, std.testing.io, &.{"bogus"}, identity, &output.writer));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "check=counter.below_six") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "marionette.reduce attempts=") != null);
}

const CapturedCounter = mar.Harness(.{
    .init = Counter.init,
    .scenario = Counter.scenario,
    .capture = captureCounter,
});

const CounterOutcome = struct {
    allocator: std.mem.Allocator,
    label: []u8,

    pub fn deinit(self: *CounterOutcome) void {
        self.allocator.free(self.label);
    }
};

fn captureCounter(case: *mar.SimCase(Counter), allocator: std.mem.Allocator) !CounterOutcome {
    return .{ .allocator = allocator, .label = try std.fmt.allocPrint(allocator, "value-{}", .{case.app.value}) };
}

test "harness: capture returns the scenario's outcome with the report" {
    var captured = try CapturedCounter.runCapture(std.testing.allocator, .{ .seed = 9 });
    defer captured.deinit();
    try std.testing.expect(captured.report == .passed);
    const outcome = captured.outcome.?;
    try std.testing.expect(std.mem.startsWith(u8, outcome.label, "value-"));
}

const Sized = struct {
    const Input = struct { size: u32, label: []const u8 };

    size: u32 = 0,

    fn init(_: mar.Sim) @This() {
        return .{ .size = SizedHarness.input().size };
    }

    fn scenario(case: *mar.SimCase(@This())) !void {
        const input = SizedHarness.input();
        case.control().record("sized.input size={} label={s}", .{ case.app.size, input.label });
        if (input.size > 10) return error.TooLarge;
    }
};

const SizedHarness = mar.Harness(.{ .init = Sized.init, .scenario = Sized.scenario, .Input = Sized.Input });

test "harness: typed inputs reach the run and replay from the capsule" {
    var report = try SizedHarness.run(std.testing.allocator, .{ .input = .{ .size = 12, .label = "big" } });
    defer report.deinit();
    try std.testing.expectEqualStrings("TooLarge", report.failed.error_name.?);
    try mar.expectTraceContains(report.failed.first_trace, "sized.input size=12 label=big");
    try mar.expectTraceContains(report.failed.first_trace, "run.attribute key=harness.input");

    const identity: mar.ReplayIdentity = .{ .build = "harness", .sut = "sized" };
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replayed = try SizedHarness.replay(std.testing.allocator, &capsule, identity);
    defer replayed.deinit();
    try std.testing.expectEqualStrings("TooLarge", replayed.failed.error_name.?);
    try std.testing.expectError(error.HarnessInputRequired, SizedHarness.run(std.testing.allocator, .{}));
}
