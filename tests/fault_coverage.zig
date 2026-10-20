//! Fault coverage counts injected faults that had an observable effect, so a
//! passing run can be told apart from one where the fault model never fired.
const std = @import("std");
const mar = @import("marionette");

const identity: mar.ReplayIdentity = .{ .build = "test-build-080", .sut = "fault-coverage-v1" };

test "fault coverage: counts effects, not injections" {
    const trace =
        "marionette.trace format=text version=4\n" ++
        "event=0 disk.crash pending_writes=3 landed=0 lost=1 torn=1 reordered=1 pending_metadata=1 metadata_kept=0 metadata_lost=1\n" ++
        "event=1 disk.fault op=1 path=wal kind=read_error rate=1/1 roll=0 fired=true\n" ++
        "event=2 disk.fault op=2 path=wal kind=write_error rate=1/2 roll=1 fired=false\n" ++
        // Crash-time rolls are already totalled by `disk.crash`.
        "event=3 disk.fault op=3 path=wal kind=crash_lost_write rate=1/1 roll=0 fired=true\n" ++
        "event=4 disk.read op=4 path=wal offset=0 len=4 status=corrupt latency_ns=0\n" ++
        "event=5 network.auto_partition node=1 isolated_count=1 connected_count=1\n" ++
        "event=6 network.drop id=1 from=1 to=0 reason=link_disabled\n" ++
        "event=7 process.kill node=1 reason=auto_crash\n" ++
        "event=8 allocation.alloc op=0 len=1 align=1 status=fail reason=quota roll=none live_bytes=0 successful_allocations=0\n" ++
        // Overflow and an unsupported in-place resize are not injected faults.
        "event=9 allocation.alloc op=1 len=1 align=1 status=fail reason=overflow roll=none live_bytes=0 successful_allocations=0\n" ++
        "event=10 allocation.resize op=2 old_len=1 new_len=2 align=1 status=fail reason=backing_unsupported roll=none live_bytes=1 successful_allocations=1\n";
    const coverage = try mar.faultCoverage(trace);
    try std.testing.expectEqual(mar.FaultCoverage{
        .disk_crashes = 1,
        .crash_lost_writes = 1,
        .crash_torn_writes = 1,
        .crash_reordered_writes = 1,
        .crash_lost_metadata = 1,
        .disk_read_errors = 1,
        .disk_corrupt_reads = 1,
        .network_partitions = 1,
        .network_drops = 1,
        .process_kills = 1,
        .allocation_failures = 1,
    }, coverage);
    try std.testing.expect(coverage.fired());

    // A crash with nothing pending and a partition that dropped nothing are
    // injections without an effect.
    const vacuous = try mar.faultCoverage(
        "event=0 disk.crash pending_writes=0 landed=0 lost=0 torn=0 reordered=0 pending_metadata=0 metadata_kept=0 metadata_lost=0\n" ++
            "event=1 network.partition left_count=1 right_count=1\n",
    );
    try std.testing.expectEqual(@as(u64, 1), vacuous.disk_crashes);
    try std.testing.expect(!vacuous.fired());

    try std.testing.expectError(error.InvalidTraceEvent, mar.faultCoverage("event=0 disk.crash pending_writes=1 lost=1\n"));
}

const Faulty = struct {
    io: std.Io,

    fn init(sim: mar.Sim) @This() {
        return .{ .io = sim.env.io() };
    }

    /// Exercise every fault model once so the counter tracks emitted events.
    fn everyModel(case: *mar.SimCase(@This())) !void {
        const disk = case.env().disk;
        const control = case.control();
        // Before the crash, which restarts every process itself.
        try case.sim.killProcess(1);
        try control.disk.setFaults(.{ .crash_lost_write_rate = .always() });
        try disk.write(.{ .path = "wal", .offset = 0, .bytes = "abcd" });
        try control.disk.crash();
        try control.disk.restart();

        try control.disk.setFaults(.{ .read_error_rate = .always() });
        var buffer: [4]u8 = undefined;
        try std.testing.expectError(error.ReadError, disk.read(.{ .path = "wal", .offset = 0, .buffer = &buffer }));
        try disk.write(.{ .path = "data", .offset = 0, .bytes = "abcd" });
        try control.disk.setFaults(.{ .corrupt_read_rate = .always() });
        try disk.read(.{ .path = "data", .offset = 0, .buffer = &buffer });

        try control.network.partition(&.{0}, &.{1});

        try control.allocation.setFaults(.{ .fail_after = 0 });
        try std.testing.expectError(error.OutOfMemory, case.env().allocator().alloc(u8, 1));
    }

    /// Inject a crash and a partition that cannot affect anything.
    fn nothingFires(case: *mar.SimCase(@This())) !void {
        const control = case.control();
        try control.disk.setFaults(.{ .crash_lost_write_rate = .always() });
        try control.disk.crash();
        try control.disk.restart();
        try control.network.partition(&.{0}, &.{1});
    }
};

fn faultyConfig(comptime scenario: anytype) FaultyConfig(scenario) {
    return .{ .allocator = std.testing.allocator };
}

fn FaultyConfig(comptime scenario_fn: anytype) type {
    return struct {
        allocator: std.mem.Allocator,
        seed: u64 = 0xFA17,
        simulate: mar.World.SimulateOptions = .{ .disk = .{ .sector_size = 4 }, .network = .{ .nodes = 2 } },
        comptime init: @TypeOf(Faulty.init) = Faulty.init,
        comptime scenario: @TypeOf(scenario_fn) = scenario_fn,
    };
}

test "fault coverage: counts the events each fault model emits" {
    var report = try mar.runSimCase(faultyConfig(Faulty.everyModel));
    defer report.deinit();
    try std.testing.expect(report == .passed);
    const coverage = try mar.faultCoverage(report.passed.trace);
    try std.testing.expectEqual(@as(u64, 1), coverage.disk_crashes);
    try std.testing.expectEqual(@as(u64, 1), coverage.crash_lost_writes);
    try std.testing.expectEqual(@as(u64, 1), coverage.disk_read_errors);
    try std.testing.expectEqual(@as(u64, 1), coverage.disk_corrupt_reads);
    try std.testing.expectEqual(@as(u64, 1), coverage.network_partitions);
    try std.testing.expectEqual(@as(u64, 1), coverage.process_kills);
    try std.testing.expectEqual(@as(u64, 1), coverage.allocation_failures);

    var summary = try mar.summarize(std.testing.allocator, report.passed.trace);
    defer summary.deinit();
    try std.testing.expectEqual(coverage, summary.faults);
}

test "fault coverage: a passing run whose faults had no effect is visible" {
    var report = try mar.runSimCase(faultyConfig(Faulty.nothingFires));
    defer report.deinit();
    try std.testing.expect(report == .passed);
    const coverage = try mar.faultCoverage(report.passed.trace);
    try std.testing.expectEqual(@as(u64, 1), coverage.disk_crashes);
    try std.testing.expectEqual(@as(u64, 1), coverage.network_partitions);
    try std.testing.expect(!coverage.fired());
}

/// Each seed decides whether a write is pending when the disk crashes.
const SometimesLoses = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }
    fn scenario(case: *mar.SimCase(@This())) !void {
        const control = case.control();
        try control.disk.setFaults(.{ .crash_lost_write_rate = .always() });
        if (try control.world.chooseBool("workload.write_before_crash")) {
            try case.env().disk.write(.{ .path = "wal", .offset = 0, .bytes = "abcd" });
        }
        try control.disk.crash();
        try control.disk.restart();
    }
};

test "fault coverage: campaigns total coverage and count fault-free cases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config = .{
        .allocator = std.testing.allocator,
        .seed = 0xC0FE,
        .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4 } },
        .init = SometimesLoses.init,
        .scenario = SometimesLoses.scenario,
    };
    var summary = try mar.runCampaign(config, .{
        .io = std.testing.io,
        .cases = 32,
        .artifacts = .{ .parent = tmp.dir, .name = "campaign", .identity = identity },
    });
    defer summary.deinit();

    try std.testing.expectEqual(@as(u64, 32), summary.faults.disk_crashes);
    // Every case either lost its one pending write or had nothing to lose.
    try std.testing.expectEqual(summary.executed_cases - summary.cases_without_faults, summary.faults.crash_lost_writes);
    try std.testing.expect(summary.cases_without_faults > 0 and summary.cases_without_faults < summary.executed_cases);

    var dir = try tmp.dir.openDir(std.testing.io, "campaign", .{});
    defer dir.close(std.testing.io);
    var loaded = try mar.loadCampaignSummary(std.testing.allocator, std.testing.io, dir);
    defer loaded.deinit();
    try std.testing.expectEqual(summary.faults, loaded.faults);
    try std.testing.expectEqual(summary.cases_without_faults, loaded.cases_without_faults);
}
