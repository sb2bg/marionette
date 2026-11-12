//! External SUT validation for xitdb running on Marionette's deterministic
//! `std.Io` backend. Every scenario is a `mar.Harness`; parameterized cases
//! carry their sector size, fault, crash budget, and plan as typed harness
//! input, so each run replays from its capsule.

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

fn restartAfterDiskCrash(sim: mar.Sim) !void {
    try sim.control.disk.restart();
    try sim.control.process.restart(0);
}

const Value = union(enum) {
    absent,
    bytes: []const u8,
    uint: u64,
};

const Snapshot = struct {
    values: [KeyCount]Value = @splat(.{ .absent = {} }),
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
    // The runner executes the seed twice and compares the traces.
    const trace = try runTrace(std.testing.allocator, 0xC0FFEE, .none);
    defer std.testing.allocator.free(trace);
}

test "xitdb acknowledged transactions survive lost-write crash" {
    const allocator = std.testing.allocator;

    const trace = try runTrace(allocator, 0x51A7E, .lost_write_crash);
    defer allocator.free(trace);
}

test "xitdb acknowledged transactions survive lost-write crash seed sweep" {
    const allocator = std.testing.allocator;

    try TraceHarness.fuzz(allocator, .{ .seed = 0x5100_0000, .input = .{ .fault_mode = .lost_write_crash } }, .{ .seeds = SweepSeeds });
}

test "xitdb data-region torn writes preserve acknowledged history at realistic sectors" {
    try runDataRegionCrashSweep(.torn);
}

test "xitdb data-region reordered writes preserve acknowledged history at realistic sectors" {
    try runDataRegionCrashSweep(.reordered);
}

test "xitdb torn header recovery stays sector atomic at sub-field geometry" {
    const allocator = std.testing.allocator;

    // The committed-size field crosses this deliberately tiny sector boundary,
    // but a torn write may still land only a prefix of whole sectors. The old
    // byte-prefix model corrupted this field and produced a false positive.
    try std.testing.expect(committedSizeHeaderCrossesSector(7));
    const outcome = try runTornHeaderRecoveryCase(allocator, 0x70A1_0007, 7);
    defer allocator.free(outcome.trace);
    try std.testing.expectEqual(TornOutcome.recovered, outcome.result);
    try mar.expectTraceContains(outcome.trace, "disk.crash_write");
    try mar.expectTraceContains(outcome.trace, "path=xit-torn.db offset=28");
    try mar.expectTraceContains(outcome.trace, "result=torn");
}

test "xitdb realistic sector sizes keep committed-size header tear atomic" {
    const allocator = std.testing.allocator;

    const sector_sizes = [_]u64{ 512, 4096 };
    for (sector_sizes) |sector_size| {
        try std.testing.expect(!committedSizeHeaderCrossesSector(sector_size));
        const outcome = try runTornHeaderRecoveryCase(allocator, 0x70A1_0000 + sector_size, sector_size);
        defer allocator.free(outcome.trace);
        try std.testing.expectEqual(TornOutcome.recovered, outcome.result);
        try mar.expectTraceContains(outcome.trace, "disk.crash_write");
        try mar.expectTraceContains(outcome.trace, "path=xit-torn.db offset=0");
        try mar.expectTraceContains(outcome.trace, "result=torn");
    }
}

fn committedSizeHeaderCrossesSector(sector_size: u64) bool {
    const first_sector = committed_size_header_offset / sector_size;
    const last_byte = committed_size_header_offset + committed_size_header_len - 1;
    const last_sector = last_byte / sector_size;
    return first_sector != last_sector;
}

const MvccApp = struct {
    fn init(_: mar.Sim) MvccApp {
        return .{};
    }

    fn run(case: *mar.SimCase(MvccApp)) !void {
        const allocator = case.control().harnessAllocator();
        const io = case.env().io();
        var file = try std.Io.Dir.cwd().createFile(io, "xit-mvcc.db", .{ .read = true, .truncate = true });
        defer file.close(io);

        var db = try DB.init(.{ .io = io, .file = file });
        var model = std.ArrayList(Snapshot).empty;
        defer model.deinit(allocator);

        try runRandomWorkload(allocator, case.control(), &db, &model, 1);

        const old_history = try DB.ArrayList(.read_only).init(db.rootCursor().readOnly());
        const old_cursor = (try old_history.getCursor(0)).?;
        const old_moment = try DB.HashMap(.read_only).init(old_cursor);
        const old_snapshot = model.items[0];

        try runRandomWorkload(allocator, case.control(), &db, &model, 8);
        try verifyHistory(allocator, &db, model.items);
        try verifySnapshot(allocator, old_moment, old_snapshot);
    }
};

test "xitdb old read-only moments survive later writes" {
    const H = mar.Harness(.{
        .init = MvccApp.init,
        .scenario = MvccApp.run,
        .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4096 } },
        .name = "xitdb.mvcc",
    });
    try H.expectPass(std.testing.allocator, .{ .seed = 0x0A11_CE });
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
                @as(u64, @intCast(@backingInt(fault))) * 0x10000 +
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
        }

        try std.testing.expect(windows > 0);
        try std.testing.expect(data_faults > 0);
    }
}

const DataRegionInput = struct {
    sector_size: u64,
    fault: DataRegionFault,
    warmup_transactions: usize,
};

const DataRegionApp = struct {
    probe: DataRegionProbe = .{ .trace = &.{}, .unacknowledged_window = false, .data_region_faulted = false },

    fn init(_: mar.Sim) DataRegionApp {
        return .{};
    }

    fn run(case: *mar.SimCase(DataRegionApp)) !void {
        const input = DataRegionHarness.input();
        const control = case.control();
        const allocator = control.harnessAllocator();
        const io = case.env().io();

        var file = try std.Io.Dir.cwd().createFile(io, "xit-data.db", .{ .read = true, .truncate = true });
        defer file.close(io);

        var db = try DB.init(.{ .io = io, .file = file });
        var model = std.ArrayList(Snapshot).empty;
        defer model.deinit(allocator);

        try runRandomWorkload(allocator, control, &db, &model, input.warmup_transactions);
        const grow_ops = [_]Operation{
            .{ .put_bytes = .{ .key_index = 0, .value = data_probe_value[0..] } },
        };
        try applyTransaction(&db, &grow_ops);
        try appendModelTransaction(allocator, &model, &grow_ops);
        try verifyHistory(allocator, &db, model.items);

        try control.disk.setFaults(.{ .write_error_rate = .oneIn(8) });
        const failed = blk: {
            const key_index = try control.chooseIntLessThan("xitdb.victim_key", usize, KeyCount);
            const unacknowledged_ops = [_]Operation{
                .{ .put_bytes = .{ .key_index = key_index, .value = data_probe_value[0..] } },
            };
            applyTransaction(&db, &unacknowledged_ops) catch break :blk true;
            break :blk false;
        };
        if (!failed) return;

        switch (input.fault) {
            .torn => try control.disk.setFaults(.{ .crash_torn_write_rate = .always() }),
            .reordered => try control.disk.setFaults(.{ .crash_reordered_write_rate = .always() }),
        }
        try control.disk.crash();
        try restartAfterDiskCrash(case.sim);

        // The crash killed the simulated process; reopen the database file
        // like a restarted process before recovering.
        var recovered_file = try std.Io.Dir.cwd().openFile(io, "xit-data.db", .{ .mode = .read_write });
        defer recovered_file.close(io);
        var recovered = try DB.init(.{ .io = io, .file = recovered_file });
        try verifyHistory(allocator, &recovered, model.items);

        case.app.probe.unacknowledged_window = true;
        case.app.probe.data_region_faulted = switch (input.fault) {
            inline else => |fault| traceHasDataRegionFault(control.traceBytes(), input.sector_size, fault),
        };
    }

    fn capture(case: *mar.SimCase(DataRegionApp), _: std.mem.Allocator) !DataRegionProbe {
        return case.app.probe;
    }
};

const DataRegionHarness = mar.Harness(.{
    .init = DataRegionApp.init,
    .scenario = DataRegionApp.run,
    .capture = DataRegionApp.capture,
    .Input = DataRegionInput,
    .name = "xitdb.data_region",
});

fn runDataRegionCrashCase(
    allocator: std.mem.Allocator,
    seed: u64,
    sector_size: u64,
    comptime fault: DataRegionFault,
    warmup_transactions: usize,
) !DataRegionProbe {
    var captured = try DataRegionHarness.runCapture(allocator, .{
        .seed = seed,
        .simulate = .{ .disk = .{ .sector_size = sector_size } },
        .input = .{ .sector_size = sector_size, .fault = fault, .warmup_transactions = warmup_transactions },
    });
    defer captured.deinit();
    switch (captured.report) {
        .passed => {
            var probe = captured.outcome.?;
            probe.trace = &.{};
            return probe;
        },
        .failed => |failure| {
            failure.print();
            return error.AcknowledgedHistoryLost;
        },
    }
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

const TornApp = struct {
    result: TornOutcome = .recovery_corrupted,

    fn init(_: mar.Sim) TornApp {
        return .{};
    }

    fn run(case: *mar.SimCase(TornApp)) !void {
        const control = case.control();
        const allocator = control.harnessAllocator();
        const io = case.env().io();

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

        try control.disk.setFaults(.{ .crash_torn_write_rate = .always() });
        try control.disk.crash();
        try restartAfterDiskCrash(case.sim);

        // The crash killed the simulated process; reopen the database file
        // like a restarted process before recovering.
        var recovered_file = try std.Io.Dir.cwd().openFile(io, "xit-torn.db", .{ .mode = .read_write });
        defer recovered_file.close(io);
        var recovered = try DB.init(.{ .io = io, .file = recovered_file });
        case.app.result = if (verifyHistory(allocator, &recovered, model.items)) |_| .recovered else |err| switch (err) {
            error.EndOfStream => .recovery_corrupted,
            else => |e| return e,
        };
    }

    fn capture(case: *mar.SimCase(TornApp), _: std.mem.Allocator) !TornOutcome {
        return case.app.result;
    }
};

const TornHarness = mar.Harness(.{
    .init = TornApp.init,
    .scenario = TornApp.run,
    .capture = TornApp.capture,
    .name = "xitdb.torn_header",
});

fn runTornHeaderRecoveryCase(allocator: std.mem.Allocator, seed: u64, sector_size: u64) !TornResult {
    var captured = try TornHarness.runCapture(allocator, .{
        .seed = seed,
        .simulate = .{ .disk = .{ .sector_size = sector_size } },
    });
    defer captured.deinit();
    switch (captured.report) {
        .passed => |passed| return .{
            .result = captured.outcome.?,
            .trace = try allocator.dupe(u8, passed.trace),
        },
        .failed => |failure| {
            failure.print();
            return error.ScenarioFailed;
        },
    }
}

test "xitdb modeled workload matches host std.Io file behavior" {
    const allocator = std.testing.allocator;

    const plan = makeHostRandomPlan(0xFACE_FEED);

    var captured = try ParityHarness.runCapture(allocator, .{ .seed = 0xFACE_FEED, .input = .{ .plan_seed = 0xFACE_FEED } });
    defer captured.deinit();
    if (captured.report == .failed) captured.report.failed.print();
    const sim_model = captured.outcome orelse return error.ScenarioFailed;

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

    try std.testing.expectEqualSlices(Snapshot, sim_model.snapshots, prod_model.items);
}

const ParityModel = struct {
    allocator: std.mem.Allocator,
    snapshots: []Snapshot,

    pub fn deinit(self: *ParityModel) void {
        self.allocator.free(self.snapshots);
    }
};

const ParityApp = struct {
    model: std.ArrayList(Snapshot) = .empty,
    allocator: std.mem.Allocator,

    fn init(sim: mar.Sim) ParityApp {
        return .{ .allocator = sim.control.harnessAllocator() };
    }

    pub fn deinit(self: *ParityApp) void {
        self.model.deinit(self.allocator);
    }

    fn run(case: *mar.SimCase(ParityApp)) !void {
        const plan = makeHostRandomPlan(ParityHarness.input().plan_seed);
        const io = case.env().io();
        var file = try std.Io.Dir.cwd().createFile(io, "xit-parity.db", .{ .read = true, .truncate = true });
        defer file.close(io);
        var db = try DB.init(.{ .io = io, .file = file });
        try runPlan(case.app.allocator, &db, &case.app.model, &plan);
        try verifyHistory(case.app.allocator, &db, case.app.model.items);
    }

    fn capture(case: *mar.SimCase(ParityApp), allocator: std.mem.Allocator) !ParityModel {
        return .{ .allocator = allocator, .snapshots = try allocator.dupe(Snapshot, case.app.model.items) };
    }
};

const ParityHarness = mar.Harness(.{
    .init = ParityApp.init,
    .scenario = ParityApp.run,
    .capture = ParityApp.capture,
    .Input = struct { plan_seed: u64 },
    .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4096 } },
    .name = "xitdb.host_parity",
});

const FaultMode = enum {
    none,
    lost_write_crash,
};

const TraceApp = struct {
    fn init(_: mar.Sim) TraceApp {
        return .{};
    }

    fn run(case: *mar.SimCase(TraceApp)) !void {
        const fault_mode = TraceHarness.input().fault_mode;
        const control = case.control();
        const allocator = control.harnessAllocator();
        const io = case.env().io();

        var file = try std.Io.Dir.cwd().createFile(io, "xit.db", .{ .read = true, .truncate = true });
        defer file.close(io);

        var db = try DB.init(.{ .io = io, .file = file });
        var model = std.ArrayList(Snapshot).empty;
        defer model.deinit(allocator);

        const transaction_count = switch (fault_mode) {
            .none => TransactionCount,
            .lost_write_crash => 1 + try control.chooseIntLessThan("xitdb.transaction_count", usize, TransactionCount),
        };

        try runRandomWorkload(allocator, control, &db, &model, transaction_count);
        try verifyHistory(allocator, &db, model.items);

        switch (fault_mode) {
            .none => {
                try appendTrailingJunkAndVerifyRecovery(allocator, io, file, &db, model.items);
            },
            .lost_write_crash => {
                try control.disk.setFaults(.{ .crash_lost_write_rate = .always() });
                try control.disk.crash();
                try restartAfterDiskCrash(case.sim);

                // The crash killed the simulated process; reopen the database
                // file like a restarted process before recovering.
                var recovered_file = try std.Io.Dir.cwd().openFile(io, "xit.db", .{ .mode = .read_write });
                defer recovered_file.close(io);
                var recovered = try DB.init(.{ .io = io, .file = recovered_file });
                try verifyHistory(allocator, &recovered, model.items);
            },
        }
    }
};

const TraceHarness = mar.Harness(.{
    .init = TraceApp.init,
    .scenario = TraceApp.run,
    .Input = struct { fault_mode: FaultMode },
    .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4096 } },
    .name = "xitdb.workload",
});

fn runTrace(allocator: std.mem.Allocator, seed: u64, fault_mode: FaultMode) ![]u8 {
    var report = try TraceHarness.run(allocator, .{ .seed = seed, .input = .{ .fault_mode = fault_mode } });
    defer report.deinit();
    switch (report) {
        .passed => |passed| return allocator.dupe(u8, passed.trace),
        .failed => |failure| {
            failure.print();
            return error.ScenarioFailed;
        },
    }
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
    control: mar.Control,
    db: *DB,
    model: *std.ArrayList(Snapshot),
    transaction_count: usize,
) !void {
    for (0..transaction_count) |tx_index| {
        var ops_buffer: [MaxOpsPerTransaction]Operation = undefined;
        const op_count = 1 + try control.chooseIntLessThan("xitdb.op_count", usize, MaxOpsPerTransaction);
        for (ops_buffer[0..op_count]) |*op| {
            op.* = try randomOperation(control, tx_index);
        }

        try applyTransaction(db, ops_buffer[0..op_count]);
        try appendModelTransaction(allocator, model, ops_buffer[0..op_count]);
    }
}

fn randomOperation(control: mar.Control, tx_index: usize) !Operation {
    const key_index = try control.chooseIntLessThan("xitdb.key", usize, KeyCount);
    const kind = try control.chooseIntLessThan("xitdb.op_kind", u8, 3);
    return switch (kind) {
        0 => .{ .put_bytes = .{
            .key_index = key_index,
            .value = byte_values[try control.chooseIntLessThan("xitdb.bytes_value", usize, byte_values.len)],
        } },
        1 => .{ .put_uint = .{
            .key_index = key_index,
            .value = @as(u64, tx_index) * 100 + try control.chooseIntLessThan("xitdb.uint_value", u64, 100),
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
    // Opening is read-only in the new xitdb pin: another writer may own the
    // tail. Recovery truncates it when a write cursor is initialized.
    try std.testing.expectEqual(len_before_junk + "junk after committed file size".len, try reopened.core.length());
    try verifyHistory(allocator, &reopened, model);
    _ = try DB.ArrayList(.read_write).init(reopened.rootCursor());
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
    /// The crash interrupted the victim after its commit point, so it
    /// survived whole without being acknowledged.
    passed_victim_survived,
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

/// One planned operation as harness input: byte values name an entry of
/// `byte_values`, so the plan round-trips through a capsule.
const PlanOp = union(enum) {
    put_bytes: struct { key_index: usize, value_index: usize },
    put_uint: struct { key_index: usize, value: u64 },
    remove: struct { key_index: usize },
};

const FuzzInput = struct {
    sector_size: u64,
    fault: FuzzFault,
    crash_after_ops: u64,
    /// Transactions in order; the last is the victim.
    plan: []const []const PlanOp,
};

fn planOp(op: Operation) PlanOp {
    return switch (op) {
        .put_bytes => |put| .{ .put_bytes = .{
            .key_index = put.key_index,
            .value_index = for (byte_values, 0..) |value, index| {
                if (std.mem.eql(u8, value, put.value)) break index;
            } else unreachable,
        } },
        .put_uint => |put| .{ .put_uint = .{ .key_index = put.key_index, .value = put.value } },
        .remove => |remove| .{ .remove = .{ .key_index = remove.key_index } },
    };
}

fn transactionFromPlan(ops: []const PlanOp) Transaction {
    var transaction = Transaction{};
    for (ops) |op| {
        transaction.ops[transaction.op_count] = switch (op) {
            .put_bytes => |put| .{ .put_bytes = .{ .key_index = put.key_index, .value = byte_values[put.value_index] } },
            .put_uint => |put| .{ .put_uint = .{ .key_index = put.key_index, .value = put.value } },
            .remove => |remove| .{ .remove = .{ .key_index = remove.key_index } },
        };
        transaction.op_count += 1;
    }
    return transaction;
}

const FuzzApp = struct {
    outcome: FuzzOutcome = .failed,

    fn init(_: mar.Sim) FuzzApp {
        return .{};
    }

    fn run(case: *mar.SimCase(FuzzApp)) !void {
        case.app.outcome = try fuzzCaseBody(case.sim, FuzzHarness.input());
    }

    fn capture(case: *mar.SimCase(FuzzApp), _: std.mem.Allocator) !FuzzOutcome {
        return case.app.outcome;
    }
};

const FuzzHarness = mar.Harness(.{
    .init = FuzzApp.init,
    .scenario = FuzzApp.run,
    .capture = FuzzApp.capture,
    .Input = FuzzInput,
    .name = "xitdb.crash_fuzz",
});

/// Run one planned crash-fault case through its harness. The last
/// transaction in `plan` is the victim: it runs as a cooperative task while
/// an operation-count crash is armed, so the crash can land mid-commit with
/// pending writes.
fn runFuzzCase(
    allocator: std.mem.Allocator,
    params: FuzzParams,
    plan: []const Transaction,
) !FuzzOutcome {
    std.debug.assert(plan.len >= 1);
    const plan_ops = try allocator.alloc([]PlanOp, plan.len);
    defer allocator.free(plan_ops);
    var built: usize = 0;
    defer for (plan_ops[0..built]) |ops| allocator.free(ops);
    for (plan, 0..) |transaction, index| {
        plan_ops[index] = try allocator.alloc(PlanOp, transaction.op_count);
        built += 1;
        for (transaction.slice(), plan_ops[index]) |op, *out| out.* = planOp(op);
    }
    var captured = try FuzzHarness.runCapture(allocator, .{
        .seed = params.seed,
        .tick_ns = fuzz_tick_ns,
        .simulate = .{ .disk = .{ .sector_size = params.sector_size, .min_latency_ns = fuzz_tick_ns } },
        .input = .{
            .sector_size = params.sector_size,
            .fault = params.fault,
            .crash_after_ops = params.crash_after_ops,
            .plan = @ptrCast(plan_ops),
        },
    });
    defer captured.deinit();
    switch (captured.report) {
        .passed => return captured.outcome.?,
        .failed => |failure| {
            failure.print();
            return error.ScenarioFailed;
        },
    }
}

fn fuzzCaseBody(sim: mar.Sim, input: FuzzInput) !FuzzOutcome {
    const allocator = sim.control.harnessAllocator();
    const io = sim.env.io();

    var file = try std.Io.Dir.cwd().createFile(io, "xit-fuzz.db", .{ .read = true, .truncate = true });
    defer file.close(io);

    var db = try DB.init(.{ .io = io, .file = file });
    var model = std.ArrayList(Snapshot).empty;
    defer model.deinit(allocator);

    for (input.plan[0 .. input.plan.len - 1]) |ops| {
        const transaction = transactionFromPlan(ops);
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

    try sim.control.disk.setFaults(input.fault.diskFaults());
    try sim.control.disk.crashAfterOps(input.crash_after_ops);

    const victim = transactionFromPlan(input.plan[input.plan.len - 1]);
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
    try restartAfterDiskCrash(sim);

    // Any failure from reopen onward means acknowledged history did not
    // recover; the classification does not distinguish how it failed.
    var victim_survived = false;
    const recovered_ok = blk: {
        var recovered_file = std.Io.Dir.cwd().openFile(io, "xit-fuzz.db", .{ .mode = .read_write }) catch
            break :blk false;
        defer recovered_file.close(io);
        var recovered = DB.init(.{ .io = io, .file = recovered_file }) catch break :blk false;
        // A crash after the victim's commit point but before it returned
        // leaves it durable yet unacknowledged: it may survive, but whole.
        if (window_opened) {
            const history = DB.ArrayList(.read_only).init(recovered.rootCursor().readOnly()) catch break :blk false;
            if ((history.count() catch break :blk false) == model.items.len + 1) {
                appendModelTransaction(allocator, &model, victim.slice()) catch break :blk false;
                victim_survived = true;
            }
        }
        verifyHistory(allocator, &recovered, model.items) catch break :blk false;
        break :blk true;
    };

    if (!recovered_ok) return .failed;
    if (victim_survived) return .passed_victim_survived;
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
                    @as(u64, @intCast(@backingInt(fault))) * 0x10000 +
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
                if (outcome != .passed_no_window) windows += 1;
            }
            // The sweep must actually exercise unacknowledged windows, not
            // just clean shutdowns.
            try std.testing.expect(windows > 0);
        }
    }
}

test "xitdb unacknowledged victim survives whole when the crash follows its commit point" {
    // Found by the xitdb-acknowledged-history campaign (XITDB-003): a crash
    // after the victim's committed-size header write lands, but before the
    // transaction returns, leaves it durable yet unacknowledged. The oracle
    // must accept that whole transaction and still reject any partial one.
    const allocator = std.testing.allocator;
    var survived: usize = 0;
    for (0..4) |i| {
        const seed = 0x5C0F_0000 + @as(u64, @intCast(i));
        var plan = try makeFuzzPlan(allocator, seed, 2);
        defer plan.deinit(allocator);
        var crash_after: u64 = 0;
        while (true) : (crash_after += 1) {
            const outcome = try runFuzzCase(allocator, .{
                .seed = seed,
                .sector_size = 512,
                .fault = .reordered,
                .crash_after_ops = crash_after,
            }, plan.items);
            if (outcome == .passed_no_window) break;
            try std.testing.expect(outcome != .failed);
            if (outcome == .passed_victim_survived) survived += 1;
        }
    }
    try std.testing.expect(survived > 0);
}

test "xitdb fuzzer rejects the former sub-field torn header artifact" {
    const allocator = std.testing.allocator;

    // Exhaust the same deliberately tiny sector profile that used to produce
    // XITDB-001. Whole-sector prefix tears must preserve acknowledged history
    // even when the header itself crosses a sector boundary.
    try std.testing.expect(committedSizeHeaderCrossesSector(7));

    var windows: usize = 0;
    for (0..4) |i| {
        const seed = 0x5421_0000 + @as(u64, @intCast(i));
        var plan = try makeFuzzPlan(allocator, seed, 2);
        defer plan.deinit(allocator);

        // The scan is self-bounding: a budget past the victim's last operation
        // never fires and reports `passed_no_window`.
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
            try std.testing.expect(outcome != .failed);
            windows += 1;
        }
    }

    try std.testing.expect(windows > 0);
}

fn hashInt(buffer: []const u8) HashInt {
    var hash: [@bitSizeOf(HashInt) / 8]u8 = undefined;
    std.crypto.hash.Sha1.hash(buffer, &hash, .{});
    return std.mem.readInt(HashInt, &hash, .big);
}

fn syncRoot(io: std.Io) !void {
    var root = try std.Io.Dir.cwd().openFile(io, ".", .{ .allow_directory = true });
    defer root.close(io);
    try root.sync(io);
}

/// A crash-point sweep over one xitdb commit under a named crash profile.
/// Setup makes the database durable, including its name, so the sweep tests
/// the commit rather than first initialization. With `sync_parent` false
/// the harness forgets the parent-directory sync: the paired broken
/// workload, which lost_write must expose.
fn XitdbCommitSweep(comptime sync_parent: bool) type {
    return struct {
        const App = @This();
        const path = "xit-sweep.db";

        fn init(_: mar.Sim) App {
            return .{};
        }

        fn scenario(case: *mar.SimCase(App)) !void {
            const allocator = std.testing.allocator;
            const io = case.env().io();
            var plan = try makeFuzzPlan(allocator, 0x0830_5EED, 3);
            defer plan.deinit(allocator);
            var model = std.ArrayList(Snapshot).empty;
            defer model.deinit(allocator);
            const victim = plan.items[plan.items.len - 1];

            var acknowledged = false;
            var fired = false;
            {
                var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
                defer file.close(io);
                var db = try DB.init(.{ .io = io, .file = file });
                for (plan.items[0 .. plan.items.len - 1]) |transaction| {
                    try applyTransaction(&db, transaction.slice());
                    try appendModelTransaction(allocator, &model, transaction.slice());
                }
                try file.sync(io);
                if (sync_parent) try syncRoot(io);

                try case.armCrashPoint();
                const committed = applyTransaction(&db, victim.slice());
                fired = try case.finishCrashPoint();
                if (committed) |_| {
                    acknowledged = true;
                } else |err| if (!fired) return err;
            }
            if (acknowledged) try appendModelTransaction(allocator, &model, victim.slice());
            // Recovery always starts from a crash under the sweep's profile.
            if (!fired) try case.control().disk.crash();
            try case.control().disk.restart();
            try case.control().process.restart(0);

            var recovered_file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch
                return error.AcknowledgedHistoryLost;
            defer recovered_file.close(io);
            var recovered = DB.init(.{ .io = io, .file = recovered_file }) catch return error.AcknowledgedHistoryLost;
            if (!acknowledged) {
                // Durable but unacknowledged: the victim may survive, whole.
                const history = try DB.ArrayList(.read_only).init(recovered.rootCursor().readOnly());
                if (try history.count() == model.items.len + 1) try appendModelTransaction(allocator, &model, victim.slice());
            }
            verifyHistory(allocator, &recovered, model.items) catch return error.AcknowledgedHistoryLost;
        }

        const Config = struct {
            allocator: std.mem.Allocator = std.testing.allocator,
            seed: u64 = 0x083,
            simulate: mar.World.SimulateOptions = .{ .disk = .{ .sector_size = 512 } },
            comptime init: @TypeOf(init) = init,
            comptime scenario: @TypeOf(scenario) = scenario,
        };
    };
}

test "xitdb commit survives every crash point under each named crash profile" {
    inline for (.{ mar.CrashProfile.lost_write, mar.CrashProfile.torn_write, mar.CrashProfile.mixed }) |profile| {
        var result = try mar.sweepCrashPoints(XitdbCommitSweep(true).Config{}, .{ .profile = profile, .require = .data });
        defer result.deinit();
        if (result.failure) |failure| {
            failure.failed.print();
            return error.AcknowledgedHistoryLost;
        }
        try std.testing.expect(result.effective > 0);
    }
}

test "xitdb harness without a parent sync loses history under lost_write" {
    const config: XitdbCommitSweep(false).Config = .{};
    try mar.expectCrashPointsPass(config, .{ .profile = .clean });
    var result = try mar.sweepCrashPoints(config, .{ .profile = .lost_write });
    defer result.deinit();
    const failure = result.failure orelse return error.MutantSurvived;
    try std.testing.expectEqualStrings("AcknowledgedHistoryLost", failure.failed.error_name.?);
}
