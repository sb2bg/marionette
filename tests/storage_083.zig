//! 0.8.3 storage correctness under `portable_v2`: data durability is
//! separate from namespace durability. These are the permanent regressions
//! for the rename and empty-creation findings, the specified crash outcomes
//! of replacement, truncation, deletion, and recreation, and paired
//! correct/broken workloads that a crash-point sweep must tell apart.
const std = @import("std");
const mar = @import("marionette");

const identity: mar.ReplayIdentity = .{ .build = "test-build-083", .sut = "storage-083" };

fn syncRoot(io: std.Io) !void {
    var root = try std.Io.Dir.cwd().openFile(io, ".", .{ .allow_directory = true });
    defer root.close(io);
    try root.sync(io);
}

fn recover(sim: mar.World.Simulation) !void {
    try sim.control.disk.restart();
    try sim.control.process.restart(0);
}

fn noopRestart(_: *anyopaque, _: mar.Env) anyerror!void {}

fn simulateWithProcess(world: *mar.World) !mar.World.Simulation {
    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    try sim.registerProcess(0, .{ .ptr = world, .restart = noopRestart });
    return sim;
}

// -- Findings from SIMULATOR_FINDINGS.md, reproduced through std.Io --------

test "083: rename cannot stand in for a missing file sync" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 7 });
    defer world.deinit();
    const sim = try simulateWithProcess(&world);
    const io = sim.env.io();
    const cwd = std.Io.Dir.cwd();

    var temporary = try cwd.createFile(io, "temporary", .{});
    try temporary.writePositionalAll(io, "DATA", 0);
    temporary.close(io);
    try cwd.rename("temporary", cwd, "final", io);
    try syncRoot(io);

    try sim.control.disk.crashWith(.lost_write);
    try recover(sim);

    // The parent sync made the name durable; nothing made the data durable.
    var final = try cwd.openFile(io, "final", .{});
    defer final.close(io);
    try std.testing.expectEqual(@as(u64, 0), try final.length(io));
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, "temporary", .{}));
    try mar.expectTraceContains(world.traceBytes(), "disk.crash_write op=");
    try mar.expectTraceContains(world.traceBytes(), "path=temporary offset=0 len=4 result=lost");
}

test "083: directory sync preserves an empty creation against lost writes" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 7 });
    defer world.deinit();
    const sim = try simulateWithProcess(&world);
    const io = sim.env.io();
    const cwd = std.Io.Dir.cwd();

    var empty = try cwd.createFile(io, "empty", .{});
    empty.close(io);
    try syncRoot(io);

    try sim.control.disk.setFaults(.{ .crash_lost_write_rate = .always() });
    try sim.control.disk.crash();
    try recover(sim);

    var reopened = try cwd.openFile(io, "empty", .{});
    defer reopened.close(io);
    try std.testing.expectEqual(@as(u64, 0), try reopened.length(io));
}

test "083: without directory sync an empty creation is lost with its namespace" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 7 });
    defer world.deinit();
    const sim = try simulateWithProcess(&world);
    const io = sim.env.io();
    const cwd = std.Io.Dir.cwd();

    var empty = try cwd.createFile(io, "empty", .{});
    try empty.sync(io);
    empty.close(io);

    // A file sync makes data durable, not the name.
    try sim.control.disk.setFaults(.{ .crash_lost_metadata_rate = .always() });
    try sim.control.disk.crash();
    try recover(sim);
    try std.testing.expectError(error.FileNotFound, cwd.openFile(io, "empty", .{}));
}

// -- Specified crash outcomes over the raw disk capability ------------------

const Raw = struct {
    world: mar.World,
    sim: mar.World.Simulation = undefined,

    fn init(self: *Raw) !void {
        self.world = try mar.World.init(std.testing.allocator, .{ .seed = 83 });
        self.sim = try self.world.simulate(.{ .disk = .{ .sector_size = 4 } });
    }

    fn deinit(self: *Raw) void {
        self.world.deinit();
    }

    fn disk(self: *Raw) mar.Disk {
        return self.sim.env.disk;
    }

    fn durable(self: *Raw, path: []const u8, bytes: []const u8) !void {
        try self.disk().write(.{ .path = path, .offset = 0, .bytes = bytes });
        try self.disk().sync(.{ .path = path });
        try self.disk().syncDir(.{ .path = "." });
    }

    fn crash(self: *Raw, faults: mar.DiskFaultOptions) !void {
        try self.sim.control.disk.setFaults(faults);
        try self.sim.control.disk.crash();
        try self.sim.control.disk.restart();
    }

    fn expectContents(self: *Raw, path: []const u8, expected: []const u8) !void {
        const stat = try self.disk().stat(.{ .path = path });
        try std.testing.expectEqual(@as(u64, expected.len), stat.size);
        var buffer: [16]u8 = undefined;
        const read_len = try self.disk().readSome(.{ .path = path, .offset = 0, .buffer = &buffer });
        try std.testing.expectEqualStrings(expected, buffer[0..read_len]);
    }

    fn expectAbsent(self: *Raw, path: []const u8) !void {
        try std.testing.expectError(error.FileNotFound, self.disk().stat(.{ .path = path }));
    }
};

const lose_everything: mar.DiskFaultOptions = .{ .crash_lost_write_rate = .always(), .crash_lost_metadata_rate = .always() };
const lose_namespace: mar.DiskFaultOptions = .{ .crash_lost_metadata_rate = .always() };

test "083: a lost replacement restores the replaced identity and its durable data" {
    var raw: Raw = undefined;
    try raw.init();
    defer raw.deinit();
    try raw.durable("final", "OLD1");
    try raw.disk().write(.{ .path = "final.tmp", .offset = 0, .bytes = "NEW1" });
    try raw.disk().sync(.{ .path = "final.tmp" });
    try raw.disk().rename(.{ .old_path = "final.tmp", .new_path = "final" });

    try raw.crash(lose_everything);
    try raw.expectContents("final", "OLD1");
    // The temporary's creation was never made durable either.
    try raw.expectAbsent("final.tmp");
}

test "083: a replaced identity keeps its own pending data for a lost rename" {
    inline for (.{ .{ lose_namespace, "OLD2" }, .{ mar.DiskFaultOptions{}, "NEW1" } }) |case| {
        var raw: Raw = undefined;
        try raw.init();
        defer raw.deinit();
        try raw.durable("final", "OLD1");
        try raw.durable("final.tmp", "NEW1");
        // Unsynced data on the identity that the rename replaces.
        try raw.disk().write(.{ .path = "final", .offset = 0, .bytes = "OLD2" });
        try raw.disk().rename(.{ .old_path = "final.tmp", .new_path = "final" });

        try raw.crash(case[0]);
        try raw.expectContents("final", case[1]);
    }
    // When the rename survives, the replaced identity's data has nowhere to land.
    var raw: Raw = undefined;
    try raw.init();
    defer raw.deinit();
    try raw.durable("final", "OLD1");
    try raw.durable("final.tmp", "NEW1");
    try raw.disk().write(.{ .path = "final", .offset = 0, .bytes = "OLD2" });
    try raw.disk().rename(.{ .old_path = "final.tmp", .new_path = "final" });
    try raw.crash(.{});
    try mar.expectTraceContains(raw.world.traceBytes(), "path=final offset=0 len=4 result=orphaned");
    try mar.expectTraceContains(raw.world.traceBytes(), "orphaned=1");
}

test "083: unsynced data stays pending across rename and lands under the new name" {
    var raw: Raw = undefined;
    try raw.init();
    defer raw.deinit();
    try raw.durable("log", "AAAA");
    try raw.disk().write(.{ .path = "log", .offset = 0, .bytes = "BBBB" });
    try raw.disk().rename(.{ .old_path = "log", .new_path = "log.old" });
    try raw.disk().syncDir(.{ .path = "." });
    // Syncing the new name syncs the identity's data.
    try raw.disk().sync(.{ .path = "log.old" });

    try raw.crash(lose_everything);
    try raw.expectContents("log.old", "BBBB");
    try raw.expectAbsent("log");
}

test "083: truncation is pending data on the identity" {
    // Lost: the durable length and bytes remain.
    {
        var raw: Raw = undefined;
        try raw.init();
        defer raw.deinit();
        try raw.durable("log", "ABCDEFGH");
        try raw.disk().setLength(.{ .path = "log", .len = 4 });
        try raw.expectContents("log", "ABCD");
        try raw.crash(lose_everything);
        try raw.expectContents("log", "ABCDEFGH");
    }
    // Landed or synced: the new length is durable.
    inline for (.{ false, true }) |synced| {
        var raw: Raw = undefined;
        try raw.init();
        defer raw.deinit();
        try raw.durable("log", "ABCDEFGH");
        try raw.disk().setLength(.{ .path = "log", .len = 4 });
        if (synced) try raw.disk().sync(.{ .path = "log" });
        try raw.crash(if (synced) lose_everything else .{});
        try raw.expectContents("log", "ABCD");
    }
    // Writes and length changes apply in issue order on the identity.
    {
        var raw: Raw = undefined;
        try raw.init();
        defer raw.deinit();
        try raw.durable("log", "ABCDEFGH");
        try raw.disk().setLength(.{ .path = "log", .len = 0 });
        try raw.disk().write(.{ .path = "log", .offset = 4, .bytes = "WXYZ" });
        const zeros: [4]u8 = @splat(0);
        try raw.expectContents("log", &zeros ++ "WXYZ");
        try raw.crash(.{});
        try raw.expectContents("log", &zeros ++ "WXYZ");
    }
}

test "083: a lost delete restores the file with whatever of its data survives" {
    inline for (.{ .{ lose_everything, "DATA" }, .{ lose_namespace, "XXXX" } }) |case| {
        var raw: Raw = undefined;
        try raw.init();
        defer raw.deinit();
        try raw.durable("victim", "DATA");
        try raw.disk().write(.{ .path = "victim", .offset = 0, .bytes = "XXXX" });
        try raw.disk().delete(.{ .path = "victim" });
        try raw.expectAbsent("victim");

        try raw.crash(case[0]);
        try raw.expectContents("victim", case[1]);
    }
}

test "083: torn writes and length changes land in the selected order" {
    inline for (.{ false, true }) |reorder| {
        inline for (.{ false, true }) |truncate_first| {
            var raw: Raw = undefined;
            try raw.init();
            defer raw.deinit();
            try raw.durable("f", "OLD-DATA");
            if (truncate_first) try raw.disk().setLength(.{ .path = "f", .len = 0 });
            try raw.disk().write(.{ .path = "f", .offset = 0, .bytes = "NEW-DATA" });
            if (!truncate_first) try raw.disk().setLength(.{ .path = "f", .len = 0 });
            try raw.crash(.{
                .crash_torn_write_rate = .always(),
                .crash_reordered_write_rate = if (reorder) .always() else .never(),
            });
            // Four-byte sectors make the eight-byte write tear to "NEW-".
            // A truncation applied afterward must erase that prefix.
            try raw.expectContents("f", if (truncate_first != reorder) "NEW-" else "");
            const effects = try mar.crashEffects(raw.world.traceBytes());
            try std.testing.expectEqual(@as(u64, if (reorder) 2 else 1), effects.data_effects);
        }
    }
}

test "083: a durable delete discards the identity's pending data" {
    var raw: Raw = undefined;
    try raw.init();
    defer raw.deinit();
    try raw.durable("victim", "DATA");
    try raw.disk().write(.{ .path = "victim", .offset = 0, .bytes = "XXXX" });
    try raw.disk().delete(.{ .path = "victim" });
    try raw.disk().syncDir(.{ .path = "." });
    try raw.crash(lose_namespace);
    try raw.expectAbsent("victim");
    try mar.expectTraceContains(raw.world.traceBytes(), "disk.crash pending_writes=0 ");
}

test "083: recreation is a new identity with its own durability" {
    inline for (.{ .{ false, "OLD1" }, .{ true, "NEW1" } }) |case| {
        var raw: Raw = undefined;
        try raw.init();
        defer raw.deinit();
        try raw.durable("f", "OLD1");
        try raw.disk().delete(.{ .path = "f" });
        try raw.disk().write(.{ .path = "f", .offset = 0, .bytes = "NEW1" });
        try raw.disk().sync(.{ .path = "f" });
        if (case[0]) try raw.disk().syncDir(.{ .path = "." });

        try raw.crash(lose_everything);
        try raw.expectContents("f", case[1]);
    }
}

test "083: crash profiles are named and their resolved rates are traced" {
    var raw: Raw = undefined;
    try raw.init();
    defer raw.deinit();
    try raw.sim.control.disk.setFaults(.{ .read_error_rate = .{ .numerator = 1, .denominator = 9 } });
    inline for (.{
        .{ mar.CrashProfile.clean, "disk.crash_profile name=clean lost_write=0/1 torn_write=0/1 reordered_write=0/1 lost_metadata=0/1" },
        .{ mar.CrashProfile.lost_write, "disk.crash_profile name=lost_write lost_write=1/1 torn_write=0/1 reordered_write=0/1 lost_metadata=1/1" },
        .{ mar.CrashProfile.torn_write, "disk.crash_profile name=torn_write lost_write=0/1 torn_write=1/1 reordered_write=0/1 lost_metadata=0/1" },
        .{ mar.CrashProfile.mixed, "disk.crash_profile name=mixed lost_write=1/4 torn_write=1/4 reordered_write=1/4 lost_metadata=1/2" },
    }) |case| {
        try raw.sim.control.disk.setCrashProfile(case[0]);
        try mar.expectTraceContains(raw.world.traceBytes(), case[1]);
    }
    // Profiles replace only crash-time rates.
    const faults = mar.DiskFaultOptions{ .read_error_rate = .always(), .capacity_bytes = 8 };
    const resolved = faults.withCrashProfile(.lost_write);
    try std.testing.expectEqual(faults.read_error_rate, resolved.read_error_rate);
    try std.testing.expectEqual(faults.capacity_bytes, resolved.capacity_bytes);
    try std.testing.expectEqual(mar.CrashProfile.lost_write.rates().lost_metadata, resolved.crash_lost_metadata_rate);
}

test "083: crash effects separate injection, eligibility, and effect" {
    var raw: Raw = undefined;
    try raw.init();
    defer raw.deinit();
    // Nothing pending: injected, not eligible.
    try raw.sim.control.disk.crashWith(.lost_write);
    try raw.sim.control.disk.restart();
    var effects = try mar.crashEffects(raw.world.traceBytes());
    try std.testing.expectEqual(mar.CrashEffects{ .injected = 1 }, effects);

    // Pending state under a clean profile: eligible, no effect.
    try raw.disk().write(.{ .path = "a", .offset = 0, .bytes = "DATA" });
    try raw.sim.control.disk.crashWith(.clean);
    try raw.sim.control.disk.restart();
    effects = try mar.crashEffects(raw.world.traceBytes());
    try std.testing.expectEqual(mar.CrashEffects{ .injected = 2, .eligible = 1 }, effects);

    // Data on a never-durable identity is orphaned with its creation: the
    // rolled-back create is the only effect.
    try raw.disk().write(.{ .path = "b", .offset = 0, .bytes = "DATA" });
    try raw.sim.control.disk.crashWith(.lost_write);
    try raw.sim.control.disk.restart();
    effects = try mar.crashEffects(raw.world.traceBytes());
    try std.testing.expectEqual(mar.CrashEffects{ .injected = 3, .eligible = 2, .metadata_effects = 1 }, effects);
    try mar.expectTraceContains(raw.world.traceBytes(), "path=b offset=0 len=4 result=orphaned");

    // Pending data on a durable name and a pending create: both effects.
    try raw.durable("c", "");
    try raw.disk().write(.{ .path = "c", .offset = 0, .bytes = "DATA" });
    try raw.disk().write(.{ .path = "d", .offset = 0, .bytes = "" });
    try raw.sim.control.disk.crashWith(.lost_write);
    try raw.sim.control.disk.restart();
    effects = try mar.crashEffects(raw.world.traceBytes());
    try std.testing.expectEqual(mar.CrashEffects{ .injected = 4, .eligible = 3, .data_effects = 1, .metadata_effects = 2 }, effects);
}

// -- Paired correct and deliberately broken workloads -----------------------

const Mutation = enum { correct, no_file_sync, no_dir_sync };

/// Publish `final` by atomic replacement, acknowledge it, then keep working
/// so the sweep crashes after the acknowledgement too. Invariant: once
/// acknowledged, `final` holds the published bytes; before that, `final` is
/// either absent or complete.
fn AtomicReplace(comptime mutation: Mutation) type {
    return struct {
        const App = @This();
        acknowledged: bool = false,

        fn init(_: mar.Sim) App {
            return .{};
        }

        fn publish(io: std.Io) !void {
            const cwd = std.Io.Dir.cwd();
            var file = try cwd.createFile(io, "final.tmp", .{});
            defer file.close(io);
            try file.writePositionalAll(io, "DATA", 0);
            if (mutation != .no_file_sync) try file.sync(io);
            try cwd.rename("final.tmp", cwd, "final", io);
            if (mutation != .no_dir_sync) try syncRoot(io);
        }

        fn laterWork(io: std.Io) !void {
            var file = try std.Io.Dir.cwd().createFile(io, "later", .{});
            defer file.close(io);
            try file.writePositionalAll(io, "MORE", 0);
            try file.sync(io);
        }

        fn scenario(case: *mar.SimCase(App)) !void {
            const io = case.env().io();
            try case.armCrashPoint();
            const completed = blk: {
                publish(io) catch |err| break :blk err;
                case.app.acknowledged = true;
                laterWork(io) catch |err| break :blk err;
            };
            const fired = try case.finishCrashPoint();
            if (completed) |_| return else |err| if (!fired) return err;
            try case.control().disk.restart();
            try case.control().process.restart(0);
        }

        fn published(case: *const mar.SimCase(App)) !void {
            const disk = case.env().disk;
            const stat = disk.stat(.{ .path = "final" }) catch |err| switch (err) {
                error.FileNotFound => if (case.app.acknowledged) return error.AcknowledgedFileMissing else return,
                else => return err,
            };
            var buffer: [4]u8 = undefined;
            const read_len = try disk.readSome(.{ .path = "final", .offset = 0, .buffer = &buffer });
            if (stat.size != 4 or !std.mem.eql(u8, buffer[0..read_len], "DATA")) return error.PublishedFileIncomplete;
        }

        const checks = [_]mar.StateCheck(mar.SimCase(App)){.{ .name = "replace.published", .check = published }};

        const Config = struct {
            allocator: std.mem.Allocator = std.testing.allocator,
            seed: u64 = 0x083,
            simulate: mar.World.SimulateOptions = .{ .disk = .{ .sector_size = 4 } },
            comptime init: @TypeOf(init) = init,
            comptime scenario: @TypeOf(scenario) = scenario,
            comptime checks: []const mar.StateCheck(mar.SimCase(App)) = &checks,
        };
    };
}

/// Create an empty marker, acknowledge it, then keep working. Invariant:
/// an acknowledged marker exists after any crash.
fn EmptyMarker(comptime mutation: Mutation) type {
    return struct {
        const App = @This();
        acknowledged: bool = false,

        fn init(_: mar.Sim) App {
            return .{};
        }

        fn create(io: std.Io) !void {
            var file = try std.Io.Dir.cwd().createFile(io, "marker", .{});
            file.close(io);
            if (mutation != .no_dir_sync) try syncRoot(io);
        }

        fn scenario(case: *mar.SimCase(App)) !void {
            const io = case.env().io();
            try case.armCrashPoint();
            const completed = blk: {
                create(io) catch |err| break :blk err;
                case.app.acknowledged = true;
                AtomicReplace(.correct).laterWork(io) catch |err| break :blk err;
            };
            const fired = try case.finishCrashPoint();
            if (completed) |_| return else |err| if (!fired) return err;
            try case.control().disk.restart();
            try case.control().process.restart(0);
        }

        fn present(case: *const mar.SimCase(App)) !void {
            if (!case.app.acknowledged) return;
            _ = case.env().disk.stat(.{ .path = "marker" }) catch return error.AcknowledgedMarkerMissing;
        }

        const checks = [_]mar.StateCheck(mar.SimCase(App)){.{ .name = "marker.present", .check = present }};

        const Config = struct {
            allocator: std.mem.Allocator = std.testing.allocator,
            seed: u64 = 0x083,
            simulate: mar.World.SimulateOptions = .{ .disk = .{ .sector_size = 4 } },
            comptime init: @TypeOf(init) = init,
            comptime scenario: @TypeOf(scenario) = scenario,
            comptime checks: []const mar.StateCheck(mar.SimCase(App)) = &checks,
        };
    };
}

fn expectMutantFails(comptime Workload: type, expected_error: []const u8) !void {
    const config: Workload.Config = .{};
    // Without a crash the mutant is indistinguishable from the correct code.
    try mar.expectSimPass(config);

    var result = try mar.sweepCrashPoints(config, .{ .profile = .lost_write });
    defer result.deinit();
    const failure = result.failure orelse return error.MutantSurvived;
    try std.testing.expectEqualStrings(expected_error, failure.failed.error_name.?);
    try mar.expectTraceContains(failure.failed.first_trace, "run.attribute key=marionette.crash_profile value=string:lost_write");
    try mar.expectTraceContains(failure.failed.first_trace, "disk.crash_profile name=lost_write");
    // The failing point had pending state for the profile to act on.
    const effects = try mar.crashEffects(failure.failed.first_trace);
    try std.testing.expectEqual(@as(u64, 1), effects.eligible);

    // Exact replay and reduction under the portable_v2 identity.
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &failure, identity);
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replayed = try mar.replaySimCase(config, &capsule, identity);
    defer replayed.deinit();
    try std.testing.expectEqualStrings(expected_error, replayed.failed.error_name.?);
    var reduced = try mar.reduceCapsule(config, &capsule, identity, .{});
    defer reduced.deinit();
    try std.testing.expectEqualStrings(expected_error, reduced.report().failed.error_name.?);
}

test "083: correct atomic replacement survives every lost_write crash point" {
    // Correct code syncs data before its name becomes durable, so the only
    // possible effects are rolled-back namespace changes; unsynced data of a
    // never-durable identity is orphaned with it.
    var result = try mar.sweepCrashPoints(AtomicReplace(.correct).Config{}, .{ .profile = .lost_write, .require = .metadata });
    defer result.deinit();
    try std.testing.expect(result.failure == null);
    try std.testing.expect(result.injected + 1 == result.points);
    try std.testing.expect(result.effective != 0 and result.effective <= result.eligible);
    try std.testing.expect(result.eligible <= result.injected);
}

test "083: atomic replacement without a file sync fails at an eligible point" {
    try expectMutantFails(AtomicReplace(.no_file_sync), "PublishedFileIncomplete");
}

test "083: atomic replacement without a parent sync fails at an eligible point" {
    try expectMutantFails(AtomicReplace(.no_dir_sync), "AcknowledgedFileMissing");
}

test "083: a directory-synced empty marker survives every lost_write crash point" {
    try mar.expectCrashPointsPass(EmptyMarker(.correct).Config{}, .{ .profile = .lost_write, .require = .metadata });
}

test "083: an empty marker without a parent sync fails at an eligible point" {
    try expectMutantFails(EmptyMarker(.no_dir_sync), "AcknowledgedMarkerMissing");
}

test "083: a sweep can require effects a clean profile never produces" {
    try mar.expectCrashPointsPass(AtomicReplace(.no_file_sync).Config{}, .{ .profile = .clean });
    try std.testing.expectError(
        error.CrashEffectRequirementUnmet,
        mar.sweepCrashPoints(AtomicReplace(.correct).Config{}, .{ .profile = .clean, .require = .data }),
    );
}
