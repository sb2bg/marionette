//! Campaign workload: pinned, unmodified xitdb on Marionette's simulated disk.
//! Acknowledged transactions are recorded in an exact model; a victim
//! transaction then commits while a seed-chosen crash with lost, torn, or
//! reordered pending writes lands inside its commit path.
//!
//! `acknowledged_history_checks` is the real durability contract and is
//! expected to hold: acknowledged transactions survive exactly, and the
//! victim either vanishes or survives whole. `victim_durable_checks` deliberately also demands the
//! victim, which was never acknowledged, so a campaign finds, retains, and
//! reduces an expected loss. It is an oracle mutation, not a bug claim.
const std = @import("std");
const mar = @import("marionette");
const xitdb = @import("xitdb");

const HashInt = u160;
const DB = xitdb.Database(.file, HashInt);
const max_read_bytes = 64;
const max_ops = 4;
const max_warmup = 6;
const db_path = "xit-campaign.db";

pub const tick_ns: u64 = 10;

pub fn simulateOptions() mar.World.SimulateOptions {
    return .{
        .disk = .{ .sector_size = 512, .min_latency_ns = tick_ns },
        .step_budget = 200_000,
    };
}

const keys = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" };
const byte_values = [_][]const u8{ "marionette", "xitdb", "simdisk", "durable", "replay", "model" };

const Value = union(enum) { absent, bytes: []const u8, uint: u64 };
const Snapshot = struct { values: [keys.len]Value = @splat(.absent) };
const Operation = union(enum) {
    put_bytes: struct { key: usize, value: []const u8 },
    put_uint: struct { key: usize, value: u64 },
    remove: usize,
};
const Transaction = struct {
    ops: [max_ops]Operation = undefined,
    len: usize = 0,

    fn slice(self: *const Transaction) []const Operation {
        return self.ops[0..self.len];
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    db: DB,
    /// Every acknowledged transaction's resulting state, in commit order.
    model: std.ArrayList(Snapshot) = .empty,
    victim: Transaction = .{},
    victim_completed: bool = false,
    recovered_file: ?std.Io.File = null,
    recovered: ?DB = null,

    pub fn init(sim: mar.Sim) !App {
        const io = sim.env.io();
        const file = try std.Io.Dir.cwd().createFile(io, db_path, .{ .read = true, .truncate = true });
        errdefer file.close(io);
        return .{ .allocator = sim.env.allocator(), .io = io, .file = file, .db = try DB.init(.{ .io = io, .file = file }) };
    }

    pub fn deinit(self: *App) void {
        if (self.recovered_file) |file| file.close(self.io);
        self.file.close(self.io);
        self.model.deinit(self.allocator);
    }

    fn commit(self: *App, transaction: *const Transaction) !void {
        try applyTransaction(&self.db, transaction.slice());
        try self.acknowledge(transaction);
    }

    fn acknowledge(self: *App, transaction: *const Transaction) !void {
        try self.model.append(self.allocator, self.after(transaction));
    }

    /// The state after applying `transaction` to the last acknowledged one.
    fn after(self: *const App, transaction: *const Transaction) Snapshot {
        var next = if (self.model.items.len == 0) Snapshot{} else self.model.items[self.model.items.len - 1];
        for (transaction.slice()) |op| switch (op) {
            .put_bytes => |put| next.values[put.key] = .{ .bytes = put.value },
            .put_uint => |put| next.values[put.key] = .{ .uint = put.value },
            .remove => |key| next.values[key] = .absent,
        };
        return next;
    }

    fn runVictim(self: *App) void {
        applyTransaction(&self.db, self.victim.slice()) catch return;
        self.victim_completed = true;
    }
};

const Case = mar.SimCase(App);

fn drawTransaction(case: *Case, index: usize) !Transaction {
    const world = case.control().world;
    var transaction: Transaction = .{ .len = 1 + try world.chooseIntLessThan("xitdb.op.count", usize, max_ops) };
    for (transaction.ops[0..transaction.len]) |*op| {
        const key = try world.chooseIntLessThan("xitdb.op.key", usize, keys.len);
        op.* = switch (try world.chooseIntLessThan("xitdb.op.kind", u8, 3)) {
            0 => .{ .put_bytes = .{ .key = key, .value = byte_values[try world.chooseIntLessThan("xitdb.op.bytes", usize, byte_values.len)] } },
            1 => .{ .put_uint = .{ .key = key, .value = @as(u64, index) * 100 + try world.chooseIntLessThan("xitdb.op.uint", u64, 100) } },
            else => .{ .remove = key },
        };
    }
    return transaction;
}

fn warmupTransaction(comptime index: usize) fn (*Case) anyerror!void {
    return struct {
        fn run(case: *Case) !void {
            const transaction = try drawTransaction(case, index);
            try case.app.commit(&transaction);
        }
    }.run;
}

/// Acknowledged warmup transactions (each removable), a durability boundary,
/// then a victim transaction whose commit races a seed-placed crash.
pub fn scenario(case: *Case) !void {
    const world = case.control().world;
    const app = &case.app;
    const warmup = try world.chooseIntLessThan("xitdb.warmup", usize, max_warmup + 1);
    inline for (0..max_warmup) |index| {
        if (index < warmup) try case.action(std.fmt.comptimePrint("xitdb.tx.{d}", .{index}), warmupTransaction(index));
    }
    // Without this boundary the header written by DB.init is still pending,
    // and the crash would destroy initialization nobody acknowledged.
    try app.file.sync(app.io);

    const faults: mar.DiskFaultOptions = switch (try world.chooseIntLessThan("xitdb.fault", u8, 3)) {
        0 => .{ .crash_lost_write_rate = .always() },
        1 => .{ .crash_torn_write_rate = .always() },
        else => .{ .crash_reordered_write_rate = .always() },
    };
    try case.control().disk.setFaults(faults);
    try case.control().disk.crashAfterOps(try world.chooseIntLessThan("xitdb.crash_after_ops", u64, 48));

    app.victim = try drawTransaction(case, max_warmup);
    var victim = try std.Io.concurrent(app.io, App.runVictim, .{app});
    victim.await(app.io);
    if (case.control().disk.crash()) {
        // The budget outlasted the victim, so crash after its commit instead.
        if (!app.victim_completed) return error.VictimFailedUndisturbed;
    } else |err| switch (err) {
        error.DiskCrashed => {},
        else => |other| return other,
    }
    try world.record("xitdb.victim completed={}", .{app.victim_completed});
    if (app.victim_completed) try app.acknowledge(&app.victim);

    try case.control().disk.restart();
    try case.sim.restartProcess(0);
    const file = try std.Io.Dir.cwd().openFile(app.io, db_path, .{ .mode = .read_write });
    app.recovered_file = file;
    app.recovered = try DB.init(.{ .io = app.io, .file = file });
}

/// Acknowledged history survives exactly. A crash after the victim's commit
/// point but before it returned leaves it durable yet unacknowledged, so it
/// may also survive, but only whole.
fn acknowledgedHistory(case: *const Case) !void {
    const app = &case.app;
    const victim: ?Snapshot = if (app.victim_completed) null else app.after(&app.victim);
    _ = try verifyHistory(app.allocator, app.recovered.?, app.model.items, victim);
}

fn victimDurable(case: *const Case) !void {
    const app = &case.app;
    if (app.victim_completed) return;
    if (!try verifyHistory(app.allocator, app.recovered.?, app.model.items, app.after(&app.victim))) {
        return error.UnacknowledgedVictimLost;
    }
}

pub const acknowledged_history_checks = [_]mar.StateCheck(Case){
    .{ .name = "xitdb.acknowledged_history", .check = acknowledgedHistory },
};

pub const victim_durable_checks = [_]mar.StateCheck(Case){
    .{ .name = "xitdb.acknowledged_history", .check = acknowledgedHistory },
    .{ .name = "xitdb.unacknowledged_victim_durable", .check = victimDurable },
};

fn applyTransaction(db: *DB, ops: []const Operation) !void {
    const history = try DB.ArrayList(.read_write).init(db.rootCursor());
    const Ctx = struct {
        ops: []const Operation,

        pub fn run(self: @This(), cursor: *DB.Cursor(.read_write)) !void {
            const moment = try DB.HashMap(.read_write).init(cursor.*);
            for (self.ops) |op| switch (op) {
                .put_bytes => |put| try moment.put(hashInt(keys[put.key]), .{ .bytes = put.value }),
                .put_uint => |put| try moment.put(hashInt(keys[put.key]), .{ .uint = put.value }),
                .remove => |key| _ = try moment.remove(hashInt(keys[key])),
            };
        }
    };
    try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{ .ops = ops });
}

/// Compare recovered history with the model without printing. One more
/// moment is allowed only when it is exactly `unacknowledged`; returns whether
/// that moment survived.
fn verifyHistory(allocator: std.mem.Allocator, db: DB, model: []const Snapshot, unacknowledged: ?Snapshot) !bool {
    var copy = db;
    const history = try DB.ArrayList(.read_only).init(copy.rootCursor().readOnly());
    const count = try history.count();
    if (count < model.len) return error.AcknowledgedTransactionLost;
    if (count > model.len + @intFromBool(unacknowledged != null)) return error.UnexpectedTransactionRecovered;
    for (model, 0..) |snapshot, index| try verifyMoment(allocator, history, index, snapshot);
    if (count == model.len) return false;
    verifyMoment(allocator, history, model.len, unacknowledged.?) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PartialTransactionRecovered,
    };
    return true;
}

fn verifyMoment(allocator: std.mem.Allocator, history: DB.ArrayList(.read_only), index: usize, snapshot: Snapshot) !void {
    const moment = try DB.HashMap(.read_only).init((try history.getCursor(@intCast(index))).?);
    for (snapshot.values, keys) |expected, key| {
        const cursor = try moment.getCursor(hashInt(key));
        switch (expected) {
            .absent => if (cursor != null) return error.DeletedKeyRecovered,
            .bytes => |bytes| {
                const actual = try (cursor orelse return error.AcknowledgedKeyLost).readBytesAlloc(allocator, max_read_bytes);
                defer allocator.free(actual);
                if (!std.mem.eql(u8, bytes, actual)) return error.AcknowledgedValueChanged;
            },
            .uint => |value| {
                const actual = try (cursor orelse return error.AcknowledgedKeyLost).readUint();
                if (actual != value) return error.AcknowledgedValueChanged;
            },
        }
    }
}

fn hashInt(buffer: []const u8) HashInt {
    var hash: [@bitSizeOf(HashInt) / 8]u8 = undefined;
    std.crypto.hash.Sha1.hash(buffer, &hash, .{});
    return std.mem.readInt(HashInt, &hash, .big);
}
