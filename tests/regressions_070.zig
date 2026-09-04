//! Regression coverage promoted from the September architecture audit.
const std = @import("std");
const mar = @import("marionette");

test "SIM-001 another live process sees an acknowledged file extension" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 1 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const first_io = sim.env.io();
    const second_io = (try sim.envForNode(1)).io();
    const first = try std.Io.Dir.cwd().createFile(first_io, "shared", .{ .read = true });
    defer first.close(first_io);
    try first.writePositionalAll(first_io, "old!", 0);
    const second = try std.Io.Dir.cwd().openFile(second_io, "shared", .{ .mode = .read_write });
    defer second.close(second_io);
    try second.writePositionalAll(second_io, "new!", 4);
    try second.sync(second_io);
    try std.testing.expectEqual(@as(u64, 8), (try sim.env.disk.stat(.{ .path = "shared" })).size);
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try first.readPositionalAll(first_io, &bytes, 0));
    try std.testing.expectEqualStrings("old!new!", &bytes);
    try std.testing.expectEqual(@as(u64, 8), try first.length(first_io));
}

test "SIM-002 failed crash retains the first replay divergence" {
    // No choices occur until crash_lost_write is rolled, so an empty tape
    // must fail at precisely that boundary and retain tape_exhausted.
    var world = try mar.World.init(std.testing.allocator, .{
        .seed = 1,
        .decisions = .{ .replay = &.{} },
    });
    defer world.deinit();
    var disk = try mar.SimDisk.init(&world, .{ .sector_size = 4 });
    defer disk.deinit();
    try disk.disk().write(.{ .path = "pending", .offset = 0, .bytes = "data" });
    try disk.control().setFaults(.{ .crash_lost_write_rate = .always() });
    try std.testing.expectError(error.DecisionReplayDiverged, disk.control().crash());
    try std.testing.expect(world.decisionDivergence() != null);
    try std.testing.expectEqual(mar.DecisionDivergenceKind.tape_exhausted, world.decisionDivergence().?.kind);
    try std.testing.expectError(error.DecisionReplayDiverged, world.finishDecisionReplay());
}

const EmptyApp = struct {
    fn init(_: mar.Sim) EmptyApp {
        return .{};
    }

    fn scenario(_: *mar.SimCase(EmptyApp)) void {}
};

test "SIM-003 finite floating point run metadata must not abort the runner" {
    const attributes = [_]mar.RunAttribute{mar.runAttribute("large", @as(f64, 1e200))};
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = EmptyApp.init,
        .scenario = EmptyApp.scenario,
        .attributes = &attributes,
    });
    defer report.deinit();
    try std.testing.expect(report == .passed);
}

test "SIM-004 inferred tuple metadata survives run option conversion" {
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = EmptyApp.init,
        .scenario = EmptyApp.scenario,
        .attributes = &.{mar.runAttribute("count", @as(u64, 7))},
    });
    defer report.deinit();
    try std.testing.expect(report == .passed);
    try mar.expectTraceContains(report.passed.trace, "key=count value=uint:7");
}

test "shared filesystem: truncation direct disk mutation rename and reopen agree" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 3 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 }, .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();
    const other_io = (try sim.envForNode(1)).io();
    const file = try std.Io.Dir.cwd().createFile(io, "shared", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "abcdefgh", 0);
    const other = try std.Io.Dir.cwd().openFile(other_io, "shared", .{ .mode = .read_write });
    defer other.close(other_io);
    try other.setLength(other_io, 3);
    try std.testing.expectEqual(@as(u64, 3), try file.length(io));
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try file.readPositionalAll(io, &bytes, 0));
    try sim.env.disk.setLength(.{ .path = "shared", .len = 4 });
    try sim.env.disk.write(.{ .path = "shared", .offset = 4, .bytes = "WXYZ" });
    try std.testing.expectEqual(@as(u64, 8), try file.length(io));
    try sim.env.disk.rename(.{ .old_path = "shared", .new_path = "renamed" });
    try std.testing.expectEqual(@as(usize, 8), try file.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings("abc\x00WXYZ", &bytes);
    const reopened = try std.Io.Dir.cwd().openFile(other_io, "renamed", .{});
    defer reopened.close(other_io);
    try std.testing.expectEqual(@as(u64, 8), try reopened.length(other_io));
    try std.testing.expectEqual((try reopened.stat(other_io)).inode, (try file.stat(io)).inode);
    try std.testing.expectEqual(@as(u64, 8), (try std.Io.Dir.cwd().statFile(io, "renamed", .{})).size);
}

test "run config: inferred runtime seed cutovers and tags are owned" {
    var seed: u64 = 999;
    _ = &seed;
    var first_char: u8 = 'n';
    _ = &first_char;
    const App = struct {
        fn init(_: mar.Sim) @This() {
            return .{};
        }
        fn scenario(case: *mar.SimCase(@This())) !void {
            _ = try case.control().world.randomU64();
        }
    };
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = App.init,
        .scenario = App.scenario,
        .seed_schedule = &.{.{ .at = .{ .sim_time_ns = 0 }, .seed = seed }},
        .tags = &.{ "short", "longer-tag" },
        .name = &.{ first_char, @as(u8, 'm') },
    });
    defer report.deinit();
    try std.testing.expect(report == .passed);
    try std.testing.expectEqual(seed, report.passed.options.seed_schedule[0].seed);
    try mar.expectTraceContains(report.passed.trace, "applied_microstep=0 seed=999");
    try mar.expectTraceContains(report.passed.trace, "run.name value=nm");
}

test "direct rename keeps lock with identity when the old path is reused" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 7 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();
    const first = try std.Io.Dir.cwd().createFile(io, "a", .{ .read = true, .lock = .exclusive, .lock_nonblocking = true });
    defer first.close(io);
    try sim.env.disk.rename(.{ .old_path = "a", .new_path = "b" });
    try std.testing.expectError(error.WouldBlock, std.Io.Dir.cwd().openFile(io, "b", .{ .lock = .exclusive, .lock_nonblocking = true }));
    const replacement = try std.Io.Dir.cwd().createFile(io, "a", .{ .read = true, .lock = .exclusive, .lock_nonblocking = true });
    defer replacement.close(io);
    try std.testing.expect((try first.stat(io)).inode != (try replacement.stat(io)).inode);
    try std.testing.expectError(error.ResourceLeak, sim.control.checkResources());
    try mar.expectTraceContains(world.traceBytes(), "path=b");
}
