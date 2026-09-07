const std = @import("std");
const mar = @import("marionette");
const identity: mar.ReplayIdentity = .{ .build = "reduction-test", .sut = "actions-v1" };
const App = struct {
    broken: bool = false,
    fn init(_: mar.Sim) @This() {
        return .{};
    }
    fn noise(case: *mar.SimCase(@This())) !void {
        var bytes: [8]u8 = undefined;
        try case.control().world.randomBytes(&bytes);
        try case.env().record("app.noise", .{});
    }
    fn bug(case: *mar.SimCase(@This())) !void {
        case.app.broken = true;
    }
    fn scenario(case: *mar.SimCase(@This())) !void {
        try case.action("noise", noise);
        try case.action("bug", bug);
        try case.checkpoint("after.actions");
    }
    fn swallowed(case: *mar.SimCase(@This())) !void {
        case.app.broken = true;
        case.checkpoint("broken") catch {};
        case.app.broken = false;
        case.checkpoint("repaired") catch {};
        return error.LaterFailure;
    }
    fn check(case: *const mar.SimCase(@This())) !void {
        if (case.app.broken) return error.InvariantBroken;
    }
};
const checks = [_]mar.StateCheck(mar.SimCase(App)){
    .{ .name = "app.safety", .phase = .checkpoint, .check = App.check },
};

fn config(allocator: std.mem.Allocator) @TypeOf(.{
    .allocator = allocator,
    .simulate = mar.World.SimulateOptions{},
    .init = App.init,
    .scenario = App.scenario,
    .checks = &checks,
}) {
    return .{ .allocator = allocator, .simulate = mar.World.SimulateOptions{}, .init = App.init, .scenario = App.scenario, .checks = &checks };
}

test "checkpoints: caught failures remain primary after repair and later error" {
    try mar.expectSimFailure(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = App.init,
        .scenario = App.swallowed,
        .checks = &checks,
        .failure = mar.FailureExpectation{ .kind = .check_failed, .check_name = "app.safety", .error_name = "InvariantBroken" },
    });
}

test "reduction: removes noise, retains failure, and replays minimized capsule" {
    var reduced = try mar.reduceSimCase(config(std.testing.allocator), .{});
    defer reduced.deinit();
    try std.testing.expect(reduced.one_minimal);
    try std.testing.expect(reduced.remaining_groups < reduced.original_groups);
    const report = reduced.report();
    try std.testing.expect(report.* == .failed);
    try std.testing.expect(mar.FailureFingerprint.from(reduced.original.failed).eql(mar.FailureFingerprint.from(report.failed)));
    try std.testing.expect(std.mem.indexOf(u8, report.failed.first_trace, "app.noise") == null);
    try mar.expectTraceContains(report.failed.first_trace, "id=noise enabled=false");
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, report, identity);
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replayed = try mar.replaySimCase(config(std.testing.allocator), &capsule, identity);
    defer replayed.deinit();
    try std.testing.expect(replayed == .failed);
    try std.testing.expectEqual(mar.RunFailureKind.check_failed, replayed.failed.kind);
    try std.testing.expectEqual(@as(usize, 0), replayed.failed.second_trace.len);
}

test "reduction: exhausted budget never claims minimality" {
    var reduced = try mar.reduceSimCase(config(std.testing.allocator), .{ .max_attempts = 0 });
    defer reduced.deinit();
    try std.testing.expectEqual(@as(usize, 0), reduced.attempts);
    try std.testing.expect(!reduced.one_minimal);
    try std.testing.expect(reduced.minimized == null);
}

fn reduceAllocationCase(allocator: std.mem.Allocator) !void {
    // The runner deliberately reports callback OOM as failure data. This test
    // injects infrastructure allocation failures and checks ownership even when
    // a rejected candidate contains that failure as data.
    const failing: *std.testing.FailingAllocator = @ptrCast(@alignCast(allocator.ptr));
    {
        var reduced = mar.reduceSimCase(config(allocator), .{ .max_attempts = 2 }) catch |err| {
            if (failing.has_induced_failure) return error.OutOfMemory;
            return err;
        };
        defer reduced.deinit();
    }
    if (failing.has_induced_failure) return error.OutOfMemory;
}

test "reduction: all allocation failures release original and candidate reports" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, reduceAllocationCase, .{});
}

test "artifacts: runner writes owned replayable directory and refuses overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const artifacts: mar.ArtifactOptions = .{ .io = std.testing.io, .parent = tmp.dir, .name = "failure", .identity = identity };
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = App.init,
        .scenario = App.scenario,
        .checks = &checks,
        .artifacts = artifacts,
    });
    defer report.deinit();
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "failure/replay.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replayed = try mar.replaySimCase(config(std.testing.allocator), &capsule, identity);
    defer replayed.deinit();
    try std.testing.expectEqual(mar.RunFailureKind.check_failed, replayed.failed.kind);
    const manifest = try tmp.dir.readFileAlloc(std.testing.io, "failure/manifest.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"complete\": true") != null);
    try std.testing.expectError(error.ArtifactAlreadyExists, mar.writeRunArtifacts(std.testing.allocator, &report, artifacts));
    var invalid = artifacts;
    invalid.name = "../escape";
    try std.testing.expectError(error.InvalidArtifactPath, mar.writeRunArtifacts(std.testing.allocator, &report, invalid));
    report.failed.tape_complete = false;
    invalid.name = "incomplete";
    try mar.writeRunArtifacts(std.testing.allocator, &report, invalid);
    const partial = try tmp.dir.readFileAlloc(std.testing.io, "incomplete/manifest.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(partial);
    try std.testing.expect(std.mem.indexOf(u8, partial, "incomplete_tape") != null);
}

test "explanation: causal IDs and spans are replay stable and reject future parents" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 1 });
    defer world.deinit();
    const recorder = mar.Recorder.fromWorld(&world);
    const cause = try recorder.event("app.request", &.{}, null);
    var operation = try recorder.beginOperation("request.commit", cause);
    const event_id = try operation.event("app.persist", &.{});
    try std.testing.expect(event_id.? > operation.start.?);
    try operation.end();
    try std.testing.expectError(error.OperationEnded, operation.end());
    const count = world.nextEventIndex();
    try std.testing.expectError(error.InvalidCausalEvent, recorder.event("app.invalid", &.{}, count));
    try std.testing.expectEqual(count, world.nextEventIndex());
    var disabled = try mar.Recorder.none().beginOperation("disabled", null);
    try disabled.end();
    try std.testing.expect(disabled.start == null);
}

const ProcessApp = struct {
    io: std.Io,
    file: std.Io.File,
    recorder: mar.Recorder,
    var fail_reopen = false;
    fn init(env: mar.Env) !@This() {
        if (fail_reopen) return error.ReopenFailed;
        const io = env.io();
        const file = try std.Io.Dir.cwd().createFile(io, "state", .{ .truncate = false, .read = true });
        errdefer file.close(io);
        try env.record("process.opened", .{});
        return .{ .io = io, .file = file, .recorder = env.recorder() };
    }
    pub fn deinit(self: *@This()) void {
        self.file.close(self.io);
        self.recorder.record("process.closed", .{}) catch {};
    }
};

test "managed processes: kill, durable reopen, failed reopen, and retry" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 7 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const managed = try sim.manageProcess(ProcessApp, 0, ProcessApp.init);
    try std.testing.expectError(error.ProcessAlreadyRegistered, sim.manageProcess(ProcessApp, 0, ProcessApp.init));
    try managed.state().?.file.writeStreamingAll(managed.state().?.io, "durable");
    try managed.state().?.file.sync(managed.state().?.io);
    try sim.killProcess(0);
    try std.testing.expect(managed.state() == null);
    ProcessApp.fail_reopen = true;
    defer ProcessApp.fail_reopen = false;
    try std.testing.expectError(error.ReopenFailed, sim.restartProcess(0));
    try std.testing.expect(managed.state() == null);
    ProcessApp.fail_reopen = false;
    try sim.restartProcess(0);
    var buffer: [7]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 7), try managed.state().?.file.readPositionalAll(managed.state().?.io, &buffer, 0));
    try std.testing.expectEqualStrings("durable", &buffer);
    try sim.killProcess(0);
    try sim.control.checkResources();
}

fn processAllocationCase(allocator: std.mem.Allocator) !void {
    const Owned = struct {
        allocator: std.mem.Allocator,
        bytes: []u8,
        fn init(env: mar.Env) !@This() {
            const backing = env.recorder().world.?.allocator;
            return .{ .allocator = backing, .bytes = try backing.alloc(u8, 8) };
        }
        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.bytes);
        }
    };
    var world = try mar.World.init(allocator, .{ .seed = 7 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    _ = try sim.manageProcess(Owned, 0, Owned.init);
}

test "managed processes: allocation failure does not publish dangling lifecycle" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, processAllocationCase, .{});
}

test "reduction: zero-byte decisions are captured in the fresh executable tape" {
    const Bytes = struct {
        fn scenario(case: *mar.SimCase(App)) !void {
            var bytes: [16]u8 = undefined;
            try case.control().world.randomBytes(&bytes);
            return error.SameFailure;
        }
    };
    var reduced = try mar.reduceSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = App.init,
        .scenario = Bytes.scenario,
    }, .{});
    defer reduced.deinit();
    try std.testing.expect(reduced.one_minimal);
    try std.testing.expectEqual(@as(usize, 0), reduced.remaining_groups);
    const entries = reduced.report().failed.decision_tape.entries;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 16), entries[0].byte_value);
    try std.testing.expectEqual(@as(usize, 0), reduced.report().failed.second_trace.len);
}

test "reduction: a different reproducible failure cannot satisfy the predicate" {
    const Different = struct {
        fn scenario(case: *mar.SimCase(App)) !void {
            try case.action("bug", App.bug);
            if (case.app.broken) return error.OriginalFailure;
            return error.OtherFailure;
        }
    };
    var reduced = try mar.reduceSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = App.init,
        .scenario = Different.scenario,
    }, .{});
    defer reduced.deinit();
    try std.testing.expect(reduced.one_minimal);
    try std.testing.expectEqual(@as(usize, 1), reduced.remaining_groups);
    try std.testing.expectEqualStrings("OriginalFailure", reduced.report().failed.error_name.?);
}

fn causalAllocationCase(allocator: std.mem.Allocator) !void {
    var world = try mar.World.init(allocator, .{ .seed = 1 });
    defer world.deinit();
    const recorder = mar.Recorder.fromWorld(&world);
    const cause = try recorder.event("app.request", &.{}, null);
    var operation = try recorder.beginOperation("commit", cause);
    _ = try operation.event("app.persist", &.{});
    try operation.end();
}

test "explanation: causal event allocation failures release temporary fields" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, causalAllocationCase, .{});
}

test "managed processes: runner captures automatic cleanup before leak checks" {
    const Harness = struct {
        fn init(sim: mar.Sim) !*mar.ManagedProcess(ProcessApp) {
            return sim.manageProcess(ProcessApp, 0, ProcessApp.init);
        }
        fn scenario(_: *mar.SimCase(*mar.ManagedProcess(ProcessApp))) !void {}
    };
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = Harness.init,
        .scenario = Harness.scenario,
        .check_resources = true,
    });
    defer report.deinit();
    try std.testing.expect(report == .passed);
    try mar.expectTraceContains(report.passed.trace, "process.closed");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.passed.trace, "process.closed"));
}

fn artifactAllocationCase(allocator: std.mem.Allocator, report: *const mar.RunReport) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try mar.writeRunArtifacts(allocator, report, .{
        .io = std.testing.io,
        .parent = tmp.dir,
        .name = "run",
        .identity = identity,
    });
}

test "artifacts: allocation failure releases encoded capsule and manifest" {
    var report = try mar.runSimCase(config(std.testing.allocator));
    defer report.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, artifactAllocationCase, .{&report});
}

test "reduction: candidate plans cross watchdog isolation and exact replay" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var result = try mar.reduceSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = App.init,
        .scenario = App.scenario,
        .checks = &checks,
        .watchdog = mar.WatchdogOptions{},
    }, .{ .max_attempts = 32 });
    defer result.deinit();
    try std.testing.expect(result.one_minimal);
    try std.testing.expect(result.remaining_groups < result.original_groups);
    try std.testing.expect(result.report().failed.tape_complete);
    try std.testing.expectEqual(@as(usize, 0), result.report().failed.second_trace.len);
}
