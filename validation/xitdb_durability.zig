//! External SUT validation for xitdb running on Marionette's deterministic
//! `std.Io` backend.

const std = @import("std");
const mar = @import("marionette");
const xitdb = @import("xitdb");

const HashInt = u160;
const MaxReadBytes = 8 * 1024;
const KeyCount = 8;
const TransactionCount = 16;
const MaxOpsPerTransaction = 4;
const SweepSeeds = 64;
const DataProbeSweepSeeds = 64;
const DataProbeWarmupTransactions = 16;
const DB = xitdb.Database(.file, HashInt);
// xitdb writes the top-level committed file_size at
// DATABASE_START + byteSizeOf(ArrayListHeader) = 12 + 16.
const committed_size_header_offset = 28;
const committed_size_header_len = 8;

const keys = [_][]const u8{
    "alpha",
    "beta",
    "gamma",
    "delta",
    "epsilon",
    "zeta",
    "eta",
    "theta",
};

const byte_values = [_][]const u8{
    "marionette",
    "xitdb",
    "simdisk",
    "durable",
    "replay",
    "model",
};

const data_probe_value: [4096]u8 = @splat('d');

const Value = union(enum) {
    absent,
    bytes: []const u8,
    uint: u64,
};

const Snapshot = struct {
    values: [KeyCount]Value = [_]Value{.{ .absent = {} }} ** KeyCount,
};

const Operation = union(enum) {
    put_bytes: struct {
        key_index: usize,
        value: []const u8,
    },
    put_uint: struct {
        key_index: usize,
        value: u64,
    },
    remove: struct {
        key_index: usize,
    },
};

const Transaction = struct {
    ops: [MaxOpsPerTransaction]Operation = undefined,
    op_count: usize = 0,

    fn slice(self: *const Transaction) []const Operation {
        return self.ops[0..self.op_count];
    }
};

test "xitdb randomized file workload replays deterministically on SimDisk" {
    const allocator = std.testing.allocator;

    const first = try runTrace(allocator, 0xC0FFEE, .none);
    defer allocator.free(first);

    const second = try runTrace(allocator, 0xC0FFEE, .none);
    defer allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
}

test "xitdb acknowledged transactions survive lost-write crash" {
    const allocator = std.testing.allocator;

    const trace = try runTrace(allocator, 0x51A7E, .lost_write_crash);
    defer allocator.free(trace);
}

test "xitdb acknowledged transactions survive lost-write crash seed sweep" {
    const allocator = std.testing.allocator;

    for (0..SweepSeeds) |i| {
        const seed = 0x5100_0000 + @as(u64, @intCast(i));
        const trace = try runTrace(allocator, seed, .lost_write_crash);
        allocator.free(trace);
    }
}

test "xitdb data-region torn writes preserve acknowledged history at realistic sectors" {
    try runDataRegionCrashSweep(.torn);
}

test "xitdb data-region reordered writes preserve acknowledged history at realistic sectors" {
    try runDataRegionCrashSweep(.reordered);
}

test "marionette detects xitdb torn header corruption at sub-field granularity" {
    const allocator = std.testing.allocator;

    // This is a minimal external counterexample: one acknowledged transaction,
    // one unacknowledged torn header write, then recovery corrupts previously
    // acknowledged state. The 7-byte sector is deliberately non-realistic; see
    // the 512/4096 test below for the hardware-plausible geometries checked so
    // far.
    try std.testing.expect(committedSizeHeaderCrossesSector(7));
    const outcome = try runTornHeaderRecoveryCase(allocator, 0x70A1_0007, 7);
    defer allocator.free(outcome.trace);
    try std.testing.expectEqual(TornOutcome.recovery_corrupted, outcome.result);
    try expectTraceContains(outcome.trace, "disk.crash_write");
    try expectTraceContains(outcome.trace, "path=xit-torn.db offset=28");
    try expectTraceContains(outcome.trace, "result=torn");
}

test "xitdb realistic sector sizes keep committed-size header tear atomic" {
    const allocator = std.testing.allocator;

    const sector_sizes = [_]u64{ 512, 4096 };
    for (sector_sizes) |sector_size| {
        try std.testing.expect(!committedSizeHeaderCrossesSector(sector_size));
        const outcome = try runTornHeaderRecoveryCase(allocator, 0x70A1_0000 + sector_size, sector_size);
        defer allocator.free(outcome.trace);
        try std.testing.expectEqual(TornOutcome.recovered, outcome.result);
        try expectTraceContains(outcome.trace, "disk.crash_write");
        try expectTraceContains(outcome.trace, "path=xit-torn.db offset=0");
        try expectTraceContains(outcome.trace, "result=torn");
    }
}

fn committedSizeHeaderCrossesSector(sector_size: u64) bool {
    const first_sector = committed_size_header_offset / sector_size;
    const last_byte = committed_size_header_offset + committed_size_header_len - 1;
    const last_sector = last_byte / sector_size;
    return first_sector != last_sector;
}

test "xitdb old read-only moments survive later writes" {
    const allocator = std.testing.allocator;

    var world = try mar.World.init(allocator, .{ .seed = 0x0A11_CE });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4096 } });
    const io = sim.env.io();

    var file = try std.Io.Dir.cwd().createFile(io, "xit-mvcc.db", .{ .read = true, .truncate = true });
    defer file.close(io);

    var db = try DB.init(.{ .io = io, .file = file });
    var model = std.ArrayList(Snapshot).empty;
    defer model.deinit(allocator);

    try runRandomWorkload(allocator, &world, &db, &model, 1);

    const old_history = try DB.ArrayList(.read_only).init(db.rootCursor().readOnly());
    const old_cursor = (try old_history.getCursor(0)).?;
    const old_moment = try DB.HashMap(.read_only).init(old_cursor);
    const old_snapshot = model.items[0];

    try runRandomWorkload(allocator, &world, &db, &model, 8);
    try verifyHistory(allocator, &db, model.items);
    try verifySnapshot(allocator, old_moment, old_snapshot);
}

const TornOutcome = enum {
    recovered,
    recovery_corrupted,
};

const TornResult = struct {
    result: TornOutcome,
    trace: []u8,
};

const DataRegionFault = enum {
    torn,
    reordered,

    fn name(self: DataRegionFault) []const u8 {
        return switch (self) {
            .torn => "torn",
            .reordered => "reordered",
        };
    }

    fn traceResult(self: DataRegionFault) []const u8 {
        return switch (self) {
            .torn => "result=torn",
            .reordered => "result=reordered",
        };
    }
};

const DataRegionProbe = struct {
    trace: []u8,
    unacknowledged_window: bool,
    data_region_faulted: bool,
};

fn runDataRegionCrashSweep(comptime fault: DataRegionFault) !void {
    const allocator = std.testing.allocator;
    const sector_sizes = [_]u64{ 512, 4096 };

    for (sector_sizes) |sector_size| {
        var windows: usize = 0;
        var data_faults: usize = 0;
        for (0..DataProbeSweepSeeds) |i| {
            const seed = 0xDA7A_0000 +
                @as(u64, @intCast(@intFromEnum(fault))) * 0x10000 +
                sector_size * 0x100 +
                @as(u64, @intCast(i));
            const outcome = runDataRegionCrashCase(
                allocator,
                seed,
                sector_size,
                fault,
                DataProbeWarmupTransactions,
            ) catch |err| {
                std.debug.print(
                    "xitdb data-region {s} failure seed=0x{x} sector_size={} warmup_transactions={}\n",
                    .{ fault.name(), seed, sector_size, DataProbeWarmupTransactions },
                );
                return err;
            };
            if (outcome.unacknowledged_window) windows += 1;
            if (outcome.data_region_faulted) data_faults += 1;
            allocator.free(outcome.trace);
        }

        try std.testing.expect(windows > 0);
        try std.testing.expect(data_faults > 0);
    }
}

fn runDataRegionCrashCase(
    allocator: std.mem.Allocator,
    seed: u64,
    sector_size: u64,
    comptime fault: DataRegionFault,
    warmup_transactions: usize,
) !DataRegionProbe {
    var world = try mar.World.init(allocator, .{ .seed = seed });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = sector_size } });
    const io = sim.env.io();

    var file = try std.Io.Dir.cwd().createFile(io, "xit-data.db", .{ .read = true, .truncate = true });
    defer file.close(io);

    var db = try DB.init(.{ .io = io, .file = file });
    var model = std.ArrayList(Snapshot).empty;
    defer model.deinit(allocator);

    try runRandomWorkload(allocator, &world, &db, &model, warmup_transactions);
    const grow_ops = [_]Operation{
        .{ .put_bytes = .{ .key_index = 0, .value = data_probe_value[0..] } },
    };
    try applyTransaction(&db, &grow_ops);
    try appendModelTransaction(allocator, &model, &grow_ops);
    try verifyHistory(allocator, &db, model.items);

    try sim.control.disk.setFaults(.{ .write_error_rate = .oneIn(8) });
    const failed = blk: {
        const key_index = try world.randomIntLessThan(usize, KeyCount);
        const unacknowledged_ops = [_]Operation{
            .{ .put_bytes = .{ .key_index = key_index, .value = data_probe_value[0..] } },
        };
        applyTransaction(&db, &unacknowledged_ops) catch break :blk true;
        break :blk false;
    };

    if (!failed) {
        return .{
            .trace = try allocator.dupe(u8, world.traceBytes()),
            .unacknowledged_window = false,
            .data_region_faulted = false,
        };
    }

    switch (fault) {
        .torn => try sim.control.disk.setFaults(.{ .crash_torn_write_rate = .always() }),
        .reordered => try sim.control.disk.setFaults(.{ .crash_reordered_write_rate = .always() }),
    }
    try sim.control.disk.crash();
    try sim.control.disk.restart();

    // The crash killed the simulated process; reopen the database file
    // like a restarted process before recovering.
    var recovered_file = try std.Io.Dir.cwd().openFile(io, "xit-data.db", .{ .mode = .read_write });
    defer recovered_file.close(io);
    var recovered = try DB.init(.{ .io = io, .file = recovered_file });
    verifyHistory(allocator, &recovered, model.items) catch |err| {
        std.debug.print(
            "xitdb data-region {s} invariant violation seed=0x{x} sector_size={} trace:\n{s}\n",
            .{ fault.name(), seed, sector_size, world.traceBytes() },
        );
        return err;
    };

    const trace = try allocator.dupe(u8, world.traceBytes());
    return .{
        .trace = trace,
        .unacknowledged_window = true,
        .data_region_faulted = traceHasDataRegionFault(trace, sector_size, fault),
    };
}

fn traceHasDataRegionFault(trace: []const u8, sector_size: u64, comptime fault: DataRegionFault) bool {
    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "disk.crash_write") == null) continue;
        if (std.mem.indexOf(u8, line, "path=xit-data.db") == null) continue;
        if (std.mem.indexOf(u8, line, fault.traceResult()) == null) continue;
        const offset = parseTraceUint(line, "offset=") orelse continue;
        if (offset >= sector_size and offset != committed_size_header_offset) return true;
    }
    return false;
}

fn parseTraceUint(line: []const u8, key: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, line, key) orelse return null;
    const value_start = start + key.len;
    var value_end = value_start;
    while (value_end < line.len and line[value_end] >= '0' and line[value_end] <= '9') {
        value_end += 1;
    }
    if (value_end == value_start) return null;
    return std.fmt.parseInt(u64, line[value_start..value_end], 10) catch null;
}

fn runTornHeaderRecoveryCase(allocator: std.mem.Allocator, seed: u64, sector_size: u64) !TornResult {
    var world = try mar.World.init(allocator, .{ .seed = seed });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = sector_size } });
    const io = sim.env.io();

    var file = try std.Io.Dir.cwd().createFile(io, "xit-torn.db", .{ .read = true, .truncate = true });
    defer file.close(io);

    var db = try DB.init(.{ .io = io, .file = file });
    var model = std.ArrayList(Snapshot).empty;
    defer model.deinit(allocator);

    const ops = [_]Operation{
        .{ .put_bytes = .{ .key_index = 0, .value = "committed" } },
    };
    try applyTransaction(&db, &ops);
    try appendModelTransaction(allocator, &model, &ops);
    try verifyHistory(allocator, &db, model.items);

    var writer = db.core.writer();
    try writer.seekTo(committed_size_header_offset);
    try writer.interface.writeInt(u64, 0, .big);
    try writer.interface.flush();

    try sim.control.disk.setFaults(.{ .crash_torn_write_rate = .always() });
    try sim.control.disk.crash();
    try sim.control.disk.restart();

    // The crash killed the simulated process; reopen the database file
    // like a restarted process before recovering.
    var recovered_file = try std.Io.Dir.cwd().openFile(io, "xit-torn.db", .{ .mode = .read_write });
    defer recovered_file.close(io);
    var recovered = try DB.init(.{ .io = io, .file = recovered_file });
    const result: TornOutcome = if (verifyHistory(allocator, &recovered, model.items)) |_| .recovered else |err| switch (err) {
        error.EndOfStream => .recovery_corrupted,
        else => |e| return e,
    };

    return .{
        .result = result,
        .trace = try allocator.dupe(u8, world.traceBytes()),
    };
}

test "xitdb modeled workload matches host std.Io file behavior" {
    const allocator = std.testing.allocator;

    const plan = makeHostRandomPlan(0xFACE_FEED);

    var sim_world = try mar.World.init(allocator, .{ .seed = 0xFACE_FEED });
    defer sim_world.deinit();

    const sim = try sim_world.simulate(.{ .disk = .{ .sector_size = 4096 } });
    const sim_io = sim.env.io();

    var sim_file = try std.Io.Dir.cwd().createFile(sim_io, "xit-parity.db", .{ .read = true, .truncate = true });
    defer sim_file.close(sim_io);

    var sim_db = try DB.init(.{ .io = sim_io, .file = sim_file });
    var sim_model = std.ArrayList(Snapshot).empty;
    defer sim_model.deinit(allocator);
    try runPlan(allocator, &sim_db, &sim_model, &plan);
    try verifyHistory(allocator, &sim_db, sim_model.items);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var production = try mar.Production.init(.{
        .root_dir = tmp.dir,
        .io = std.testing.io,
        .disk = .{ .sector_size = 4096 },
    });
    defer production.deinit();

    const prod_env = production.env();
    var prod_file = try tmp.dir.createFile(prod_env.io(), "xit-parity.db", .{ .read = true, .truncate = true });
    defer prod_file.close(prod_env.io());

    var prod_db = try DB.init(.{ .io = prod_env.io(), .file = prod_file });
    var prod_model = std.ArrayList(Snapshot).empty;
    defer prod_model.deinit(allocator);
    try runPlan(allocator, &prod_db, &prod_model, &plan);
    try verifyHistory(allocator, &prod_db, prod_model.items);

    try std.testing.expectEqualSlices(Snapshot, sim_model.items, prod_model.items);
}

const FaultMode = enum {
    none,
    lost_write_crash,
};

fn runTrace(allocator: std.mem.Allocator, seed: u64, fault_mode: FaultMode) ![]u8 {
    var world = try mar.World.init(allocator, .{ .seed = seed });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4096 } });
    const io = sim.env.io();

    var file = try std.Io.Dir.cwd().createFile(io, "xit.db", .{ .read = true, .truncate = true });
    defer file.close(io);

    var db = try DB.init(.{ .io = io, .file = file });
    var model = std.ArrayList(Snapshot).empty;
    defer model.deinit(allocator);

    const transaction_count = switch (fault_mode) {
        .none => TransactionCount,
        .lost_write_crash => 1 + try world.randomIntLessThan(usize, TransactionCount),
    };

    try runRandomWorkload(allocator, &world, &db, &model, transaction_count);
    try verifyHistory(allocator, &db, model.items);

    switch (fault_mode) {
        .none => {
            try appendTrailingJunkAndVerifyRecovery(allocator, io, file, &db, model.items);
        },
        .lost_write_crash => {
            try sim.control.disk.setFaults(.{ .crash_lost_write_rate = .always() });
            try sim.control.disk.crash();
            try sim.control.disk.restart();

            // The crash killed the simulated process; reopen the database
            // file like a restarted process before recovering.
            var recovered_file = try std.Io.Dir.cwd().openFile(io, "xit.db", .{ .mode = .read_write });
            defer recovered_file.close(io);
            var recovered = try DB.init(.{ .io = io, .file = recovered_file });
            try verifyHistory(allocator, &recovered, model.items);
        },
    }

    return allocator.dupe(u8, world.traceBytes());
}

fn makeHostRandomPlan(seed: u64) [TransactionCount]Transaction {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var plan: [TransactionCount]Transaction = undefined;

    for (&plan, 0..) |*transaction, tx_index| {
        transaction.op_count = 1 + random.intRangeLessThan(usize, 0, MaxOpsPerTransaction);
        for (transaction.ops[0..transaction.op_count]) |*op| {
            op.* = hostRandomOperation(random, tx_index);
        }
    }

    return plan;
}

fn hostRandomOperation(random: std.Random, tx_index: usize) Operation {
    const key_index = random.intRangeLessThan(usize, 0, KeyCount);
    const kind = random.intRangeLessThan(u8, 0, 3);
    return switch (kind) {
        0 => .{ .put_bytes = .{
            .key_index = key_index,
            .value = byte_values[random.intRangeLessThan(usize, 0, byte_values.len)],
        } },
        1 => .{ .put_uint = .{
            .key_index = key_index,
            .value = @as(u64, tx_index) * 100 + random.intRangeLessThan(u64, 0, 100),
        } },
        else => .{ .remove = .{ .key_index = key_index } },
    };
}

fn runPlan(
    allocator: std.mem.Allocator,
    db: *DB,
    model: *std.ArrayList(Snapshot),
    plan: []const Transaction,
) !void {
    for (plan) |transaction| {
        try applyTransaction(db, transaction.slice());
        try appendModelTransaction(allocator, model, transaction.slice());
    }
}

fn runRandomWorkload(
    allocator: std.mem.Allocator,
    world: *mar.World,
    db: *DB,
    model: *std.ArrayList(Snapshot),
    transaction_count: usize,
) !void {
    for (0..transaction_count) |tx_index| {
        var ops_buffer: [MaxOpsPerTransaction]Operation = undefined;
        const op_count = 1 + try world.randomIntLessThan(usize, MaxOpsPerTransaction);
        for (ops_buffer[0..op_count]) |*op| {
            op.* = try randomOperation(world, tx_index);
        }

        try applyTransaction(db, ops_buffer[0..op_count]);
        try appendModelTransaction(allocator, model, ops_buffer[0..op_count]);
    }
}

fn randomOperation(world: *mar.World, tx_index: usize) !Operation {
    const key_index = try world.randomIntLessThan(usize, KeyCount);
    const kind = try world.randomIntLessThan(u8, 3);
    return switch (kind) {
        0 => .{ .put_bytes = .{
            .key_index = key_index,
            .value = byte_values[try world.randomIntLessThan(usize, byte_values.len)],
        } },
        1 => .{ .put_uint = .{
            .key_index = key_index,
            .value = @as(u64, tx_index) * 100 + try world.randomIntLessThan(u64, 100),
        } },
        else => .{ .remove = .{ .key_index = key_index } },
    };
}

fn applyTransaction(db: *DB, ops: []const Operation) !void {
    const history = try DB.ArrayList(.read_write).init(db.rootCursor());
    const Ctx = struct {
        ops: []const Operation,

        pub fn run(self: @This(), cursor: *DB.Cursor(.read_write)) !void {
            const moment = try DB.HashMap(.read_write).init(cursor.*);
            for (self.ops) |op| {
                switch (op) {
                    .put_bytes => |put| try moment.put(hashInt(keys[put.key_index]), .{ .bytes = put.value }),
                    .put_uint => |put| try moment.put(hashInt(keys[put.key_index]), .{ .uint = put.value }),
                    .remove => |remove| _ = try moment.remove(hashInt(keys[remove.key_index])),
                }
            }
        }
    };
    try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{ .ops = ops });
}

fn appendModelTransaction(
    allocator: std.mem.Allocator,
    model: *std.ArrayList(Snapshot),
    ops: []const Operation,
) !void {
    var next = if (model.items.len == 0) Snapshot{} else model.items[model.items.len - 1];
    for (ops) |op| {
        switch (op) {
            .put_bytes => |put| next.values[put.key_index] = .{ .bytes = put.value },
            .put_uint => |put| next.values[put.key_index] = .{ .uint = put.value },
            .remove => |remove| next.values[remove.key_index] = .{ .absent = {} },
        }
    }
    try model.append(allocator, next);
}

fn appendTrailingJunkAndVerifyRecovery(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    db: *DB,
    model: []const Snapshot,
) !void {
    const len_before_junk = try db.core.length();
    var writer = db.core.writer();
    try writer.seekTo(len_before_junk);
    try writer.interface.writeAll("junk after committed file size");
    try writer.interface.flush();
    try std.testing.expect((try db.core.length()) > len_before_junk);

    var reopened = try DB.init(.{ .io = io, .file = file });
    try std.testing.expectEqual(len_before_junk, try reopened.core.length());
    try verifyHistory(allocator, &reopened, model);
}

fn verifyHistory(allocator: std.mem.Allocator, db: *DB, model: []const Snapshot) !void {
    const history = try DB.ArrayList(.read_only).init(db.rootCursor().readOnly());
    try std.testing.expectEqual(@as(u64, @intCast(model.len)), try history.count());

    for (model, 0..) |snapshot, index| {
        const moment_cursor = (try history.getCursor(@intCast(index))).?;
        const moment = try DB.HashMap(.read_only).init(moment_cursor);
        try verifySnapshot(allocator, moment, snapshot);
    }
}

fn verifySnapshot(allocator: std.mem.Allocator, moment: DB.HashMap(.read_only), snapshot: Snapshot) !void {
    for (snapshot.values, 0..) |expected, key_index| {
        const hash = hashInt(keys[key_index]);
        switch (expected) {
            .absent => {
                try std.testing.expectEqual(@as(?DB.Cursor(.read_only), null), try moment.getCursor(hash));
            },
            .bytes => |expected_bytes| {
                const cursor = (try moment.getCursor(hash)).?;
                const actual = try cursor.readBytesAlloc(allocator, MaxReadBytes);
                defer allocator.free(actual);
                try std.testing.expectEqualStrings(expected_bytes, actual);
            },
            .uint => |expected_uint| {
                const cursor = (try moment.getCursor(hash)).?;
                try std.testing.expectEqual(expected_uint, try cursor.readUint());
            },
        }
    }
}

fn expectTraceContains(trace: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, trace, needle) != null);
}

fn hashInt(buffer: []const u8) HashInt {
    var hash: [@bitSizeOf(HashInt) / 8]u8 = undefined;
    std.crypto.hash.Sha1.hash(buffer, &hash, .{});
    return std.mem.readInt(HashInt, &hash, .big);
}
