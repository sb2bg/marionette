//! A three-node replicated service, from planted failure to preserved
//! regression, through the public runner APIs only.
//!
//! Node 0 is the primary; nodes 1 and 2 are backups. Every replica keeps an
//! append-only log in a durable file. The primary appends each write to its
//! own log, sends it over `std.Io.net` to both backups, and acknowledges it
//! once both have acknowledged. The service code below imports only `std`.
//!
//! The harness then cuts power (a `lost_write` crash), restarts every
//! replica as a managed process, which reopens and recovers its log, and
//! checks that every acknowledged write survived on every replica. The
//! planted bug acknowledges before syncing; the tests show the failure, its
//! exact capsule replay, its reduction, and its preservation as a seed
//! regression. 0.11 extends this with independent per-host power loss.

const std = @import("std");
const mar = @import("marionette");

const Io = std.Io;

pub const max_writes = 16;
const port = 7100;
const record_len = 8;

/// How a backup orders acknowledgement and durability.
pub const Mode = enum {
    /// Sync the appended record, then acknowledge it.
    sync_before_ack,
    /// The planted bug: acknowledge before the record is durable.
    ack_before_sync,
};

// -- Service (std only) ----------------------------------------------------

/// One replica's durable log.
pub const Replica = struct {
    io: Io,
    file: Io.File,
    entries: [max_writes]u64 = undefined,
    count: usize = 0,

    fn path(node: u16, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "replica-{}.log", .{node}) catch unreachable;
    }

    /// Open the log, creating it durably on first start, and recover every
    /// whole record. A torn final record is ignored.
    pub fn open(io: Io, node: u16) !Replica {
        var name_buffer: [32]u8 = undefined;
        const name = path(node, &name_buffer);
        const cwd = Io.Dir.cwd();
        const existed = if (cwd.statFile(io, name, .{})) |_| true else |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        };
        const file = try cwd.createFile(io, name, .{ .read = true, .truncate = false });
        errdefer file.close(io);
        if (!existed) {
            // The name is durable only once its directory is synced.
            var root = try cwd.openFile(io, ".", .{ .allow_directory = true });
            defer root.close(io);
            try root.sync(io);
        }

        var replica: Replica = .{ .io = io, .file = file };
        const len = try file.length(io);
        const records: usize = @intCast(@min(len / record_len, max_writes));
        for (0..records) |index| {
            var bytes: [record_len]u8 = undefined;
            if (try file.readPositionalAll(io, &bytes, index * record_len) != record_len) break;
            replica.entries[index] = std.mem.readInt(u64, &bytes, .little);
            replica.count = index + 1;
        }
        return replica;
    }

    pub fn deinit(self: *Replica) void {
        self.file.close(self.io);
    }

    fn append(self: *Replica, value: u64, durable: bool) !void {
        if (self.count == max_writes) return error.LogFull;
        var bytes: [record_len]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.file.writePositionalAll(self.io, &bytes, self.count * record_len);
        if (durable) try self.file.sync(self.io);
        self.entries[self.count] = value;
        self.count += 1;
    }
};

fn readExact(io: Io, stream: Io.net.Stream, dest: []u8) !void {
    var reader = stream.reader(io, &.{});
    reader.interface.readSliceAll(dest) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse error.Unexpected,
        else => return err,
    };
}

fn writeAll(io: Io, stream: Io.net.Stream, bytes: []const u8) !void {
    var writer = stream.writer(io, &.{});
    writer.interface.writeAll(bytes) catch |err| switch (err) {
        error.WriteFailed => return writer.err orelse error.Unexpected,
    };
}

/// Backup: append each replicated record, then acknowledge its index.
pub fn serveBackup(io: Io, replica: *Replica, listener: *Io.net.Server, mode: Mode) !void {
    const stream = try listener.accept(io);
    defer stream.close(io);
    while (true) {
        var record: [record_len]u8 = undefined;
        readExact(io, stream, &record) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        try replica.append(std.mem.readInt(u64, &record, .little), mode == .sync_before_ack);
        var ack: [record_len]u8 = undefined;
        std.mem.writeInt(u64, &ack, replica.count, .little);
        try writeAll(io, stream, &ack);
    }
}

/// Primary: append durably, replicate to every backup, and acknowledge a
/// write once every backup acknowledged it. `acknowledged` counts them.
pub fn replicate(io: Io, primary: *Replica, backups: []const Io.net.IpAddress, writes: usize, acknowledged: *usize) !void {
    var streams: [2]Io.net.Stream = undefined;
    std.debug.assert(backups.len == streams.len);
    var connected: usize = 0;
    defer for (streams[0..connected]) |stream| stream.close(io);
    for (backups, 0..) |address, index| {
        streams[index] = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
        connected += 1;
    }
    for (0..writes) |index| {
        const value: u64 = 100 + index;
        try primary.append(value, true);
        var record: [record_len]u8 = undefined;
        std.mem.writeInt(u64, &record, value, .little);
        for (streams) |stream| try writeAll(io, stream, &record);
        for (streams) |stream| {
            var ack: [record_len]u8 = undefined;
            try readExact(io, stream, &ack);
            if (std.mem.readInt(u64, &ack, .little) != index + 1) return error.UnexpectedAck;
        }
        acknowledged.* = index + 1;
    }
}

// -- Harness (Marionette) --------------------------------------------------

pub fn Service(comptime mode: Mode) type {
    return struct {
        const App = @This();
        pub const Case = mar.SimCase(App);

        replicas: [3]*mar.ManagedProcess(Replica),
        ios: [3]Io,
        control: mar.Control,
        writes: usize,
        acknowledged: usize = 0,
        listeners: [3]Io.net.Server = undefined,

        fn openReplica(comptime node: u16) fn (mar.Env) anyerror!Replica {
            return struct {
                fn open(env: mar.Env) anyerror!Replica {
                    return Replica.open(env.io(), node);
                }
            }.open;
        }

        pub fn init(sim: mar.Sim) !App {
            try sim.control.network.setLatency(.{ .min_latency_ns = 20, .latency_jitter_ns = 40 });
            var app: App = .{
                .replicas = undefined,
                .ios = undefined,
                .control = sim.control,
                // The seed chooses how much work runs before the power cut.
                .writes = 1 + try sim.control.chooseIntLessThan("replicated.writes", usize, 6),
            };
            inline for (0..3) |node| {
                app.replicas[node] = try sim.manageProcess(Replica, node, openReplica(node));
                app.ios[node] = (try sim.envForNode(node)).io();
            }
            return app;
        }

        fn backupTask(app: *App, node: usize) void {
            const replica = app.replicas[node].state() orelse return app.control.failRun(error.ReplicaDown);
            serveBackup(app.ios[node], replica, &app.listeners[node], mode) catch |err| app.control.failRun(err);
        }

        fn primaryTask(app: *App) void {
            const primary = app.replicas[0].state() orelse return app.control.failRun(error.ReplicaDown);
            const backups = [_]Io.net.IpAddress{ mar.AnyNetworkControl.hostIp4(1, port), mar.AnyNetworkControl.hostIp4(2, port) };
            replicate(app.ios[0], primary, &backups, app.writes, &app.acknowledged) catch |err| app.control.failRun(err);
            app.control.record("replicated.acknowledged count={}", .{app.acknowledged});
        }

        pub fn scenario(case: *Case) !void {
            const app = &case.app;
            inline for (1..3) |node| {
                app.listeners[node] = try mar.AnyNetworkControl.hostIp4(node, port).listen(app.ios[node], .{});
            }
            var first = try Io.concurrent(app.ios[1], backupTask, .{ app, @as(usize, 1) });
            var second = try Io.concurrent(app.ios[2], backupTask, .{ app, @as(usize, 2) });
            var primary = try Io.concurrent(app.ios[0], primaryTask, .{app});
            primary.await(app.ios[0]);
            first.await(app.ios[1]);
            second.await(app.ios[2]);
            inline for (1..3) |node| app.listeners[node].deinit(app.ios[node]);

            // Power loss: every process stops and anything unsynced is lost.
            // Each managed replica then reopens and recovers its log.
            try case.control().disk.crashWith(.lost_write);
            try case.control().disk.restart();
            inline for (0..3) |node| try case.control().process.restart(node);
        }

        fn acknowledgedWritesSurvive(case: *const Case) !void {
            for (case.app.replicas) |managed| {
                const replica = managed.state() orelse return error.ReplicaDown;
                if (replica.count < case.app.acknowledged) return error.AcknowledgedWriteLost;
                for (replica.entries[0..case.app.acknowledged], 0..) |value, index| {
                    if (value != 100 + index) return error.ReplicaDiverged;
                }
            }
        }

        pub const checks = [_]mar.StateCheck(Case){.{
            .name = "acknowledged writes survive power loss",
            .check = acknowledgedWritesSurvive,
        }};

        pub const H = mar.Harness(.{
            .name = "replicated_service",
            .init = init,
            .scenario = scenario,
            .checks = &checks,
            .simulate = mar.World.SimulateOptions{
                .network = .{ .nodes = 3 },
                .disk = .{ .sector_size = record_len },
            },
        });
    };
}

const Correct = Service(.sync_before_ack).H;
const Buggy = Service(.ack_before_sync).H;
const identity: mar.ReplayIdentity = .{ .build = "examples", .sut = "replicated_service" };

/// The seed the planted bug was first found at, kept as a regression.
pub const regression_seed: u64 = 0x5EED_0010;

test "replicated service: acknowledged writes survive power loss across seeds" {
    try Correct.fuzz(std.testing.allocator, .{ .seed = 0x0010 }, .{ .seeds = 8 });
}

test "replicated service: acknowledging before sync loses acknowledged writes" {
    var report = try Buggy.run(std.testing.allocator, .{ .seed = regression_seed });
    defer report.deinit();
    const failure = report.failed;
    try std.testing.expectEqual(mar.RunFailureKind.check_failed, failure.kind);
    try std.testing.expectEqualStrings("AcknowledgedWriteLost", failure.error_name.?);
    try mar.expectTraceContains(failure.first_trace, "disk.crash_profile name=lost_write");
    try mar.expectTraceContains(failure.first_trace, "replicated.acknowledged count=");

    // Retain the failure as a capsule and replay it exactly.
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replayed = try Buggy.replay(std.testing.allocator, &capsule, identity);
    defer replayed.deinit();
    try std.testing.expectEqualStrings("AcknowledgedWriteLost", replayed.failed.error_name.?);
    try std.testing.expectEqualStrings(failure.first_trace, replayed.failed.first_trace);

    // Reduce it; the reduced capsule still fails the same way.
    var reduced = try Buggy.reduceCapsule(std.testing.allocator, &capsule, identity, .{});
    defer reduced.deinit();
    try std.testing.expectEqualStrings("AcknowledgedWriteLost", reduced.report().failed.error_name.?);
}

test "replicated service: the planted bug stays caught at its regression seed" {
    // A seed regression is build-independent, unlike a capsule, which
    // replays only on its pinned build.
    try Buggy.expectFailure(std.testing.allocator, .{ .seed = regression_seed }, .{
        .kind = .check_failed,
        .error_name = "AcknowledgedWriteLost",
        .check_name = "acknowledged writes survive power loss",
    });
    // The corrected service passes at the same seed.
    try Correct.expectPass(std.testing.allocator, .{ .seed = regression_seed });
}
