const std = @import("std");
const builtin = @import("builtin");
const mar = @import("marionette");

const identity: mar.ReplayIdentity = .{ .build = "test-build-080", .sut = "campaign-v1" };
const watchdog_supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

/// One planted scenario error and one planted property failure, chosen per seed.
const Buggy = struct {
    broken: bool = false,

    fn init(_: mar.Sim) @This() {
        return .{};
    }
    fn scenario(case: *mar.SimCase(@This())) !void {
        switch (try case.control().world.chooseIntLessThan("workload.fault", u8, 4)) {
            0 => return error.PlantedFailure,
            1 => case.app.broken = true,
            else => {},
        }
    }
    fn invariant(case: *const mar.SimCase(@This())) !void {
        if (case.app.broken) return error.InvariantBroken;
    }
    const checks = [_]mar.StateCheck(mar.SimCase(@This())){
        .{ .name = "workload.safe", .check = invariant },
    };
};

fn buggyConfig(allocator: std.mem.Allocator) BuggyConfig {
    return .{ .allocator = allocator };
}
const BuggyConfig = struct {
    allocator: std.mem.Allocator,
    // The first failure is case 9, so index alignment is checked past zero.
    seed: u64 = 0xCA4C,
    name: []const u8 = "buggy",
    simulate: mar.World.SimulateOptions = .{},
    comptime init: @TypeOf(Buggy.init) = Buggy.init,
    comptime scenario: @TypeOf(Buggy.scenario) = Buggy.scenario,
    comptime checks: []const mar.StateCheck(mar.SimCase(Buggy)) = &Buggy.checks,
};

fn readFile(dir: std.Io.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
}

test "campaign: one replayable artifact per distinct failure identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var summary = try mar.runCampaign(buggyConfig(std.testing.allocator), .{
        .io = std.testing.io,
        .cases = 32,
        .artifacts = .{ .parent = tmp.dir, .name = "campaign", .identity = identity },
    });
    defer summary.deinit();

    try std.testing.expectEqual(mar.CampaignStopReason.completed, summary.stop_reason);
    try std.testing.expectEqual(@as(u64, 32), summary.executed_cases);
    try std.testing.expectEqual(summary.executed_cases, summary.passed_cases + summary.failed_cases);
    try std.testing.expectEqual(@as(usize, 2), summary.failures.len);
    try std.testing.expectEqual(@as(usize, 0), summary.errors.len);
    var occurrences: u64 = 0;
    for (summary.failures) |failure| occurrences += failure.occurrences;
    try std.testing.expectEqual(summary.failed_cases, occurrences);
    try std.testing.expect(summary.failures[0].occurrences > 1 or summary.failures[1].occurrences > 1);

    var campaign_dir = try tmp.dir.openDir(std.testing.io, "campaign", .{});
    defer campaign_dir.close(std.testing.io);
    for (summary.failures) |failure| {
        try std.testing.expect(failure.reproducible);
        var dir = try campaign_dir.openDir(std.testing.io, failure.artifact_name.?, .{});
        defer dir.close(std.testing.io);
        const bytes = try readFile(dir, "replay.json");
        defer std.testing.allocator.free(bytes);

        // The retained capsule alone reproduces the same failure identity.
        var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
        defer capsule.deinit();
        try std.testing.expectEqual(failure.first_seed, capsule.options().seed);
        var replay = try mar.replaySimCase(buggyConfig(std.testing.allocator), &capsule, identity);
        defer replay.deinit();
        try std.testing.expect(replay == .failed);
        try std.testing.expect(failure.fingerprint.eql(mar.FailureFingerprint.from(replay.failed)));
    }

    const summary_bytes = try readFile(campaign_dir, "campaign.json");
    defer std.testing.allocator.free(summary_bytes);
    const Recorded = struct { format: []const u8, executed_cases: u64, failed_cases: u64, stop_reason: mar.CampaignStopReason };
    const recorded = try std.json.parseFromSlice(Recorded, std.testing.allocator, summary_bytes, .{ .ignore_unknown_fields = true });
    defer recorded.deinit();
    try std.testing.expectEqualStrings("marionette.campaign", recorded.value.format);
    try std.testing.expectEqual(summary.executed_cases, recorded.value.executed_cases);
    try std.testing.expectEqual(summary.failed_cases, recorded.value.failed_cases);
}

fn fuzzBuggy(seeds: usize) !void {
    try mar.expectSimFuzz(.{
        .allocator = std.testing.allocator,
        .seed = (BuggyConfig{ .allocator = std.testing.allocator }).seed,
        .seeds = seeds,
        .simulate = mar.World.SimulateOptions{},
        .init = Buggy.init,
        .scenario = Buggy.scenario,
        .checks = &Buggy.checks,
    });
}

test "campaign: case indexes match expectSimFuzz iterations" {
    var summary = try mar.runCampaign(buggyConfig(std.testing.allocator), .{ .io = std.testing.io, .cases = 32 });
    defer summary.deinit();
    const earliest = @min(summary.failures[0].first_case, summary.failures[1].first_case);
    // Fuzzing the same base seed fails exactly at the campaign's first failure.
    try std.testing.expect(earliest > 0);
    try fuzzBuggy(earliest);
    try std.testing.expectError(error.ExpectedRunPass, fuzzBuggy(earliest + 1));
}

test "campaign: failure limit and time budget stop remaining cases" {
    var limited = try mar.runCampaign(buggyConfig(std.testing.allocator), .{ .io = std.testing.io, .cases = 32, .max_failures = 1 });
    defer limited.deinit();
    try std.testing.expectEqual(mar.CampaignStopReason.failure_limit, limited.stop_reason);
    try std.testing.expectEqual(@as(u64, 1), limited.failed_cases);
    try std.testing.expectEqual(limited.failures[0].first_case + 1, limited.executed_cases);

    var budgeted = try mar.runCampaign(buggyConfig(std.testing.allocator), .{ .io = std.testing.io, .cases = 32, .time_budget_ns = 1 });
    defer budgeted.deinit();
    try std.testing.expectEqual(mar.CampaignStopReason.time_budget, budgeted.stop_reason);
    try std.testing.expectEqual(@as(u64, 1), budgeted.executed_cases);
}

/// Seeds choose a worker crash, a non-yielding task, or a passing case.
const Hostile = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }
    fn scenario(case: *mar.SimCase(@This())) !void {
        switch (try case.control().world.chooseIntLessThan("workload.hostile", u8, 3)) {
            0 => std.process.exit(42),
            1 => {
                var counter: u64 = 0;
                while (true) {
                    counter +%= 1;
                    std.mem.doNotOptimizeAway(counter);
                }
            },
            else => {},
        }
    }
};

test "campaign: survives crashed and hung workers and keeps their diagnostics" {
    if (!watchdog_supported) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var summary = try mar.runCampaign(.{
        .allocator = std.testing.allocator,
        .seed = 0xBAD,
        .simulate = mar.World.SimulateOptions{},
        .init = Hostile.init,
        .scenario = Hostile.scenario,
        .watchdog = mar.WatchdogOptions{
            .stall_timeout_ns = 20 * std.time.ns_per_ms,
            .run_timeout_ns = 500 * std.time.ns_per_ms,
            .trace_capacity = 64 * 1024,
        },
    }, .{
        .io = std.testing.io,
        .cases = 12,
        .artifacts = .{ .parent = tmp.dir, .name = "hostile", .identity = identity },
    });
    defer summary.deinit();

    try std.testing.expectEqual(@as(u64, 12), summary.executed_cases);
    try std.testing.expect(summary.passed_cases > 0);
    var campaign_dir = try tmp.dir.openDir(std.testing.io, "hostile", .{});
    defer campaign_dir.close(std.testing.io);
    var seen_crash = false;
    var seen_stall = false;
    for (summary.failures) |failure| {
        seen_crash = seen_crash or failure.fingerprint.kind == .worker_crashed;
        seen_stall = seen_stall or failure.fingerprint.kind == .non_yielding;
        // Killed workers cannot publish a complete tape: diagnostics only.
        try std.testing.expect(!failure.reproducible);
        var failure_dir = try campaign_dir.openDir(std.testing.io, failure.artifact_name.?, .{});
        defer failure_dir.close(std.testing.io);
        const trace = try readFile(failure_dir, "trace.txt");
        defer std.testing.allocator.free(trace);
        try std.testing.expect(std.mem.indexOf(u8, trace, "watchdog.") != null);
        try std.testing.expectError(error.FileNotFound, failure_dir.access(std.testing.io, "replay.json", .{}));
    }
    try std.testing.expect(seen_crash and seen_stall);
}

test "campaign: runner errors are recorded without stopping later cases" {
    if (!watchdog_supported) return error.SkipZigTest;
    var summary = try mar.runCampaign(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = Buggy.init,
        .scenario = Buggy.scenario,
        // Every completed worker result exceeds one byte of transport.
        .watchdog = mar.WatchdogOptions{ .result_capacity = 1 },
    }, .{ .io = std.testing.io, .cases = 3 });
    defer summary.deinit();
    try std.testing.expectEqual(@as(u64, 3), summary.executed_cases);
    try std.testing.expectEqual(@as(usize, 3), summary.errors.len);
    for (summary.errors, 0..) |case_error, index| {
        try std.testing.expectEqual(@as(u64, index), case_error.case);
        try std.testing.expectEqualStrings("WatchdogTraceTooLarge", case_error.error_name);
    }
}

test "campaign: invalid options and existing directories are rejected before running" {
    const config = buggyConfig(std.testing.allocator);
    try std.testing.expectError(error.InvalidCampaignOptions, mar.runCampaign(config, .{ .io = std.testing.io, .cases = 0 }));
    try std.testing.expectError(error.InvalidCampaignOptions, mar.runCampaign(config, .{ .io = std.testing.io, .cases = 1, .max_failures = 0 }));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "taken", .default_dir);
    try std.testing.expectError(error.ArtifactAlreadyExists, mar.runCampaign(config, .{
        .io = std.testing.io,
        .cases = 1,
        .artifacts = .{ .parent = tmp.dir, .name = "taken", .identity = identity },
    }));
    try std.testing.expectError(error.InvalidArtifactPath, mar.runCampaign(config, .{
        .io = std.testing.io,
        .cases = 1,
        .artifacts = .{ .parent = tmp.dir, .name = "../escape", .identity = identity },
    }));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var summary = try mar.runCampaign(buggyConfig(allocator), .{
        .io = std.testing.io,
        .cases = 6,
        .artifacts = .{ .parent = tmp.dir, .name = "campaign", .identity = identity },
    });
    summary.deinit();
}

test "campaign: allocation failure releases retained failures and artifacts" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
