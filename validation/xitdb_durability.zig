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
        .allocator = allocator,
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

// --- Crash-fault fuzzer with shrinking -------------------------------------
//
// Fuzz cases are explicit operation plans generated from a host PRNG, not
// from the world's random stream: shrinking then removes transactions and
// operations without disturbing anything else the case does. Each case runs
// a warmup prefix of acknowledged transactions, then arms a structural
// crash trigger (`crashAfterOps`) and runs the final (victim) transaction
// as a cooperative scheduler task: the disk crashes at a seed-varied
// operation boundary inside the victim's commit path. Pending writes at the
// crash get exactly one active fault class; every acknowledged transaction
// must survive recovery.

const FuzzFault = enum {
    lost,
    torn,
    reordered,

    fn diskFaults(self: FuzzFault) mar.DiskFaultOptions {
        return switch (self) {
            .lost => .{ .crash_lost_write_rate = .always() },
            .torn => .{ .crash_torn_write_rate = .always() },
            .reordered => .{ .crash_reordered_write_rate = .always() },
        };
    }
};

const fuzz_tick_ns: u64 = 10;

const FuzzParams = struct {
    seed: u64,
    sector_size: u64,
    fault: FuzzFault,
    /// Disk operations the victim transaction completes before the armed
    /// crash fires (`control.disk.crashAfterOps`, armed after the durable
    /// setup boundary). This places the crash at a structural point of the
    /// victim's commit path with no measured timing: a budget past the
    /// victim's last operation simply never fires and the case reports
    /// `passed_no_window`.
    crash_after_ops: u64,
};

const FuzzOutcome = enum {
    /// The victim transaction committed before the crash point, so no
    /// unacknowledged window opened.
    passed_no_window,
    /// The crash interrupted the victim mid-commit and acknowledged history
    /// survived.
    passed_with_window,
    /// Acknowledged history failed to verify after crash recovery.
    failed,
};

const VictimTask = struct {
    db: *DB,
    ops: []const Operation,
    completed: bool = false,

    fn run(self: *VictimTask, io: std.Io) void {
        _ = io;
        applyTransaction(self.db, self.ops) catch return;
        self.completed = true;
    }
};

fn makeFuzzPlan(
    allocator: std.mem.Allocator,
    seed: u64,
    max_warmup: usize,
) !std.ArrayList(Transaction) {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var plan = std.ArrayList(Transaction).empty;
    errdefer plan.deinit(allocator);

    // Warmup prefix plus one victim transaction at the end.
    const warmup = random.intRangeLessThan(usize, 0, max_warmup + 1);
    for (0..warmup + 1) |tx_index| {
        var transaction = Transaction{};
        transaction.op_count = 1 + random.intRangeLessThan(usize, 0, MaxOpsPerTransaction);
        for (transaction.ops[0..transaction.op_count]) |*op| {
            op.* = hostRandomOperation(random, tx_index);
        }
        try plan.append(allocator, transaction);
    }
    return plan;
}

/// Run one planned crash-fault case. The last transaction in `plan` is the
/// victim: it runs as a cooperative task while the main context sleeps to
/// the crash point, so the crash can land mid-commit with pending writes.
fn runFuzzCase(
    allocator: std.mem.Allocator,
    params: FuzzParams,
    plan: []const Transaction,
) !FuzzOutcome {
    std.debug.assert(plan.len >= 1);

    var world = try mar.World.init(allocator, .{
        .seed = params.seed,
        .tick_ns = fuzz_tick_ns,
    });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{
        .sector_size = params.sector_size,
        .min_latency_ns = fuzz_tick_ns,
    } });
    const io = sim.env.io();

    var file = try std.Io.Dir.cwd().createFile(io, "xit-fuzz.db", .{ .read = true, .truncate = true });
    defer file.close(io);

    var db = try DB.init(.{ .io = io, .file = file });
    var model = std.ArrayList(Snapshot).empty;
    defer model.deinit(allocator);

    for (plan[0 .. plan.len - 1]) |transaction| {
        try applyTransaction(&db, transaction.slice());
        try appendModelTransaction(allocator, &model, transaction.slice());
    }

    // Setup crosses a durability boundary before the fault window opens:
    // with no warmup transactions the database header written by DB.init is
    // otherwise still pending, and the crash destroys initialization state
    // the scenario never acknowledged. (Crash-during-first-init is a real
    // scenario, but it needs its own characterized case, not a fuzz sweep
    // that conflates it with committed-history loss.)
    try file.sync(io);

    try sim.control.disk.setFaults(params.fault.diskFaults());
    try sim.control.disk.crashAfterOps(params.crash_after_ops);

    const victim = plan[plan.len - 1];
    var victim_task = VictimTask{ .db = &db, .ops = victim.slice() };
    var victim_future = try std.Io.concurrent(io, VictimTask.run, .{ &victim_task, io });
    victim_future.await(io);

    const window_opened = !victim_task.completed;
    if (victim_task.completed) {
        try appendModelTransaction(allocator, &model, victim.slice());
        // The budget outlasted the victim, so the armed crash never fired;
        // crash manually so recovery always starts from a crashed disk.
        try sim.control.disk.crash();
    } else {
        // The victim must have died to the armed crash. If the disk is
        // still running, the transaction failed undisturbed, which is a
        // harness bug rather than a finding; the probe crash doubles as
        // the check.
        if (sim.control.disk.crash()) {
            return error.VictimFailedUndisturbed;
        } else |err| switch (err) {
            error.DiskCrashed => {},
            else => |other| return other,
        }
    }
    try sim.control.disk.restart();

    // Any failure from reopen onward means acknowledged history did not
    // recover; the classification does not distinguish how it failed.
    const recovered_ok = blk: {
        var recovered_file = std.Io.Dir.cwd().openFile(io, "xit-fuzz.db", .{ .mode = .read_write }) catch
            break :blk false;
        defer recovered_file.close(io);
        var recovered = DB.init(.{ .io = io, .file = recovered_file }) catch break :blk false;
        verifyHistory(allocator, &recovered, model.items) catch break :blk false;
        break :blk true;
    };

    if (!recovered_ok) return .failed;
    return if (window_opened) .passed_with_window else .passed_no_window;
}

/// Greedy plan shrinking: repeatedly try removing one transaction, then one
/// operation at a time, keeping any candidate that still fails. The result
/// is 1-minimal: removing any single remaining transaction or operation
/// makes the failure disappear.
fn shrinkFuzzPlan(
    allocator: std.mem.Allocator,
    params: FuzzParams,
    plan: *std.ArrayList(Transaction),
) !void {
    var made_progress = true;
    while (made_progress) {
        made_progress = false;

        // Try removing whole transactions.
        var tx_index: usize = 0;
        while (tx_index < plan.items.len) {
            if (plan.items.len <= 1) break;
            const removed = plan.orderedRemove(tx_index);
            if (try runFuzzCase(allocator, params, plan.items) == .failed) {
                made_progress = true;
                continue;
            }
            try plan.insert(allocator, tx_index, removed);
            tx_index += 1;
        }

        // Try removing single operations within transactions.
        for (plan.items) |*transaction| {
            var op_index: usize = 0;
            while (op_index < transaction.op_count) {
                if (transaction.op_count <= 1) break;
                const removed = transaction.ops[op_index];
                std.mem.copyForwards(
                    Operation,
                    transaction.ops[op_index .. transaction.op_count - 1],
                    transaction.ops[op_index + 1 .. transaction.op_count],
                );
                transaction.op_count -= 1;
                if (try runFuzzCase(allocator, params, plan.items) == .failed) {
                    made_progress = true;
                    continue;
                }
                std.mem.copyBackwards(
                    Operation,
                    transaction.ops[op_index + 1 .. transaction.op_count + 1],
                    transaction.ops[op_index..transaction.op_count],
                );
                transaction.ops[op_index] = removed;
                transaction.op_count += 1;
                op_index += 1;
            }
        }
    }
}

/// Render a shrunk failing case as a maintainer-readable repro.
fn writeRepro(
    writer: *std.Io.Writer,
    params: FuzzParams,
    plan: []const Transaction,
) !void {
    try writer.print(
        "xitdb crash-fault repro: seed=0x{x} sector_size={} fault={s} crash_after_ops={}\n",
        .{ params.seed, params.sector_size, @tagName(params.fault), params.crash_after_ops },
    );
    for (plan, 0..) |transaction, tx_index| {
        const role: []const u8 = if (tx_index == plan.len - 1) "victim (crashed mid-commit)" else "acknowledged";
        try writer.print("  tx{}: {s}\n", .{ tx_index, role });
        for (transaction.slice()) |op| {
            switch (op) {
                .put_bytes => |put| try writer.print(
                    "    put {s} = bytes:{s}\n",
                    .{ keys[put.key_index], put.value },
                ),
                .put_uint => |put| try writer.print(
                    "    put {s} = uint:{}\n",
                    .{ keys[put.key_index], put.value },
                ),
                .remove => |remove| try writer.print(
                    "    remove {s}\n",
                    .{keys[remove.key_index]},
                ),
            }
        }
    }
    try writer.print(
        "  crash with {s} faults on pending writes, restart, reopen, verify acknowledged history\n",
        .{@tagName(params.fault)},
    );
}

test "xitdb crash-fault fuzz holds acknowledged history at realistic sectors" {
    const allocator = std.testing.allocator;
    const sector_sizes = [_]u64{ 512, 4096 };
    const faults = [_]FuzzFault{ .lost, .torn, .reordered };
    const seeds_per_case = 8;

    for (faults) |fault| {
        for (sector_sizes) |sector_size| {
            var windows: usize = 0;
            for (0..seeds_per_case) |i| {
                const seed = 0xF022_0000 +
                    @as(u64, @intCast(@intFromEnum(fault))) * 0x10000 +
                    sector_size * 0x10 +
                    @as(u64, @intCast(i));
                var plan = try makeFuzzPlan(allocator, seed, 6);
                defer plan.deinit(allocator);

                // A commit spans dozens of disk operations, so a seed-drawn
                // budget in 0..47 usually lands inside the victim's commit
                // path; budgets that outlast the victim report a clean
                // no-window pass and the windows counter below proves the
                // sweep still opened real ones.
                const params = FuzzParams{
                    .seed = seed,
                    .sector_size = sector_size,
                    .fault = fault,
                    .crash_after_ops = seed % 48,
                };
                const outcome = try runFuzzCase(allocator, params, plan.items);
                if (outcome == .failed) {
                    try shrinkFuzzPlan(allocator, params, &plan);
                    var buffer: [4096]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&buffer);
                    try writeRepro(&writer, params, plan.items);
                    std.debug.print("{s}", .{writer.buffered()});
                    return error.AcknowledgedHistoryLost;
                }
                if (outcome == .passed_with_window) windows += 1;
            }
            // The sweep must actually exercise unacknowledged windows, not
            // just clean shutdowns.
            try std.testing.expect(windows > 0);
        }
    }
}

test "xitdb fuzzer shrinks the sub-field torn header failure to a readable repro" {
    const allocator = std.testing.allocator;

    // Sector size 7 is the characterized XITDB-001 simulator boundary: the
    // 8-byte committed-size header spans sectors, so a torn crash write can
    // cut inside the field and corrupt recovery. The fuzzer must find it and
    // reduce it to a minimal, readable operation sequence.
    try std.testing.expect(committedSizeHeaderCrossesSector(7));

    var found = false;
    seeds: for (0..4) |i| {
        const seed = 0x5421_0000 + @as(u64, @intCast(i));
        var plan = try makeFuzzPlan(allocator, seed, 2);
        defer plan.deinit(allocator);

        // Scan every crash point in the victim's commit path: the torn
        // header window is only a slice of the commit, and the scan is the
        // fuzzer's crash-point dimension made exhaustive. The scan is
        // self-bounding: a budget past the victim's last operation never
        // fires and reports `passed_no_window`.
        var crash_after: u64 = 0;
        while (true) : (crash_after += 1) {
            const params = FuzzParams{
                .seed = seed,
                .sector_size = 7,
                .fault = .torn,
                .crash_after_ops = crash_after,
            };
            const outcome = try runFuzzCase(allocator, params, plan.items);
            if (outcome == .passed_no_window) break;
            if (outcome != .failed) continue;

            const original_len = plan.items.len;
            try shrinkFuzzPlan(allocator, params, &plan);
            try std.testing.expect(plan.items.len <= original_len);
            // The known counterexample needs almost nothing: at most the
            // victim plus a couple of acknowledged transactions.
            try std.testing.expect(plan.items.len <= 3);
            // The shrunk plan must still reproduce.
            try std.testing.expectEqual(FuzzOutcome.failed, try runFuzzCase(allocator, params, plan.items));

            var buffer: [4096]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try writeRepro(&writer, params, plan.items);
            const repro = writer.buffered();
            try std.testing.expect(std.mem.indexOf(u8, repro, "sector_size=7") != null);
            try std.testing.expect(std.mem.indexOf(u8, repro, "fault=torn") != null);
            try std.testing.expect(std.mem.indexOf(u8, repro, "victim") != null);

            found = true;
            break :seeds;
        }
    }

    try std.testing.expect(found);
}

fn hashInt(buffer: []const u8) HashInt {
    var hash: [@bitSizeOf(HashInt) / 8]u8 = undefined;
    std.crypto.hash.Sha1.hash(buffer, &hash, .{});
    return std.mem.readInt(HashInt, &hash, .big);
}
