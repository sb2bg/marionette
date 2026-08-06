//! Marionette example: WAL recovery under crash + corruption.
//!
//! - `SimCase(KVStore)` holds app state and simulator authority for each run.
//! - `scenario` drives writes, faults, crash, restart, and recovery.
//! - `checks` assert the invariant after the scenario runs.
//! - `expectSimPass` / `expectSimFuzz` / `expectSimFailure` are the runners.

const std = @import("std");
const mar = @import("marionette");
const wal_record = @import("wal_record.zig");

pub const tick_ns: mar.Duration = 1_000_000;
const wal_path = "kv.wal";
const scenario_write_count = 2;
const Record = wal_record.Fixed(u32, 4);
const record_size = Record.record_size;
const sector_size = record_size / 2;
const magic: u32 = 0x4d4b5631; // MKV1
const committed_key: u32 = 1;
const committed_value: u32 = 41;
const volatile_key: u32 = 2;
const volatile_value: u32 = 99;

pub const Case = mar.SimCase(KVStore);

pub fn simulateOptions() mar.World.SimulateOptions {
    return .{
        .disk = .{
            // Each WAL record spans two sectors, so a torn write can land a
            // truthful whole-sector prefix that strict recovery must reject.
            .sector_size = sector_size,
            .min_latency_ns = tick_ns,
        },
    };
}

pub fn init(sim: mar.Sim) !KVStore {
    try sim.registerProcess(0, .{
        .ptr = sim.control.world,
        .restart = noopProcessRestart,
    });
    return try KVStore.init(sim.env.io(), std.Io.Dir.cwd(), sim.env.recorder());
}

fn noopProcessRestart(_: *anyopaque, _: mar.Env) anyerror!void {}

fn restartAfterDiskCrash(case: *Case) !void {
    try case.control().disk.restart();
    try case.control().process.restart(0);
}

pub const checks = [_]mar.StateCheck(Case){
    .{ .name = "synced records recover and unsynced records are rejected", .check = recoveredStateIsSafe },
};

/// The store's recovery window, checked under probabilistic crash faults.
///
/// Durable truth: the synced record crossed a durability boundary before the
/// crash, so it must recover exactly as written under every crash profile.
/// Allowed damage: the unsynced record was still inside the window, so it may
/// be absent (lost or torn and rejected) or present exactly as written; a
/// recovered record with any other value means recovery accepted damage.
pub const window_checks = [_]mar.StateCheck(Case){
    .{ .name = "recovered state is within the recovery window", .check = recoveredStateIsWithinWindow },
};

pub fn scenario(case: *Case) !void {
    const store = &case.app;
    const disk = case.control().disk;

    try store.put(committed_key, committed_value, .sync);
    try disk.setFaults(.{ .crash_lost_write_rate = .always() });
    try store.put(volatile_key, volatile_value, .no_sync);
    try disk.crash();
    try restartAfterDiskCrash(case);
    try store.reopen();
    try disk.corruptSector(wal_path, record_size);
    try store.recover(.strict);
}

pub fn buggyScenario(case: *Case) !void {
    const store = &case.app;
    const disk = case.control().disk;

    try store.put(committed_key, committed_value, .sync);
    try disk.setFaults(.{ .crash_torn_write_rate = .always() });
    try store.put(volatile_key, volatile_value, .no_sync);
    try disk.crash();
    try restartAfterDiskCrash(case);
    try store.reopen();
    try store.recover(.buggy_accept_magic_only);
}

/// Probabilistic crash faults against the unsynced write only: the synced
/// record is durable truth and stays out of every crash fault's reach.
fn runProbabilisticCrash(case: *Case, mode: RecoveryMode) !void {
    const store = &case.app;
    const disk = case.control().disk;

    try store.put(committed_key, committed_value, .sync);
    try disk.setFaults(.{
        .crash_lost_write_rate = .percent(25),
        .crash_torn_write_rate = .percent(25),
    });
    try store.put(volatile_key, volatile_value, .no_sync);
    try disk.crash();
    try restartAfterDiskCrash(case);
    try store.reopen();
    try store.recover(mode);
}

pub fn probabilisticScenario(case: *Case) !void {
    try runProbabilisticCrash(case, .strict);
}

pub fn runReport(
    allocator: std.mem.Allocator,
    seed: u64,
    name: []const u8,
    comptime scenario_fn: fn (*Case) anyerror!void,
    comptime state_checks: []const mar.StateCheck(Case),
) !mar.RunReport {
    return mar.runSimCase(.{
        .allocator = allocator,
        .seed = seed,
        .tick_ns = tick_ns,
        .name = name,
        .simulate = simulateOptions(),
        .init = init,
        .scenario = scenario_fn,
        .checks = state_checks,
    });
}

fn recoveredStateIsSafe(case: *const Case) !void {
    const store = &case.app;

    if (store.countKey(committed_key) != 1 or store.valueFor(committed_key) != committed_value) {
        try store.recorder.record("kv.invariant_violation reason=committed_missing_or_wrong", .{});
        return error.CommittedRecordNotRecovered;
    }

    if (store.countKey(volatile_key) != 0) {
        try store.recorder.record("kv.invariant_violation reason=unsynced_record_recovered", .{});
        return error.UnsyncedRecordRecovered;
    }

    try store.recorder.record(
        "kv.check recovery=ok committed_key={} committed_value={} recovered_records={}",
        .{ committed_key, committed_value, store.recovered_count },
    );
}

fn recoveredStateIsWithinWindow(case: *const Case) !void {
    const store = &case.app;

    if (store.countKey(committed_key) != 1 or store.valueFor(committed_key) != committed_value) {
        try store.recorder.record("kv.invariant_violation reason=durable_truth_lost", .{});
        return error.DurableTruthLost;
    }

    const volatile_count = store.countKey(volatile_key);
    if (volatile_count > 1) {
        try store.recorder.record("kv.invariant_violation reason=duplicate_recovered", .{});
        return error.DuplicateRecovered;
    }
    const volatile_survived = volatile_count == 1;
    if (volatile_survived and store.valueFor(volatile_key) != volatile_value) {
        try store.recorder.record("kv.invariant_violation reason=damaged_record_accepted", .{});
        return error.DamagedRecordAccepted;
    }

    try store.recorder.record(
        "kv.check recovery_window=ok committed_recovered=true volatile_survived={}",
        .{volatile_survived},
    );
}

fn writeAndRecover(io: std.Io, root: std.Io.Dir, recorder: mar.Recorder) !KVStore {
    var store = try KVStore.init(io, root, recorder);
    try store.put(committed_key, committed_value, .sync);
    try store.put(volatile_key, volatile_value, .no_sync);
    try store.recover(.strict);
    return store;
}

fn expectBothRecordsRecovered(store: *const KVStore) !void {
    try std.testing.expectEqual(@as(u8, 2), store.recovered_count);
    try std.testing.expectEqual(@as(u8, 1), store.countKey(committed_key));
    try std.testing.expectEqual(@as(?u32, committed_value), store.valueFor(committed_key));
    try std.testing.expectEqual(@as(u8, 1), store.countKey(volatile_key));
    try std.testing.expectEqual(@as(?u32, volatile_value), store.valueFor(volatile_key));
}

const SyncMode = enum {
    no_sync,
    sync,
};

const RecoveryMode = enum {
    strict,
    buggy_accept_magic_only,
};

const Entry = struct {
    key: u32,
    value: u32,
};

const KVStore = struct {
    io: std.Io,
    root: std.Io.Dir,
    recorder: mar.Recorder,
    wal: std.Io.File,
    next_offset: u64 = 0,
    recovered: [scenario_write_count]Entry = undefined,
    recovered_count: u8 = 0,

    fn init(io: std.Io, root: std.Io.Dir, recorder: mar.Recorder) !KVStore {
        return .{
            .io = io,
            .root = root,
            .recorder = recorder,
            .wal = try root.createFile(io, wal_path, .{ .read = true }),
        };
    }

    pub fn deinit(self: *KVStore) void {
        self.wal.close(self.io);
    }

    /// Reacquire the WAL handle after a simulated restart.
    ///
    /// A disk crash kills the simulated process, so open handles die with
    /// it; recovery code must reopen its files like a freshly started
    /// process would.
    fn reopen(self: *KVStore) !void {
        self.wal.close(self.io);
        self.wal = try self.root.openFile(self.io, wal_path, .{ .mode = .read_write });
        try self.recorder.record("kv.reopen path={s}", .{wal_path});
    }

    fn put(self: *KVStore, key: u32, value: u32, sync_mode: SyncMode) !void {
        std.debug.assert(self.next_offset / record_size < scenario_write_count);

        var bytes: [record_size]u8 = @splat(0);
        encodeRecord(&bytes, .{ .key = key, .value = value });

        const offset = self.next_offset;
        try self.wal.writePositionalAll(self.io, &bytes, offset);
        self.next_offset += record_size;

        if (sync_mode == .sync) {
            try self.wal.sync(self.io);
        }

        try self.recorder.record(
            "kv.put key={} value={} offset={} sync={s}",
            .{ key, value, offset, @tagName(sync_mode) },
        );
    }

    fn recover(self: *KVStore, mode: RecoveryMode) !void {
        self.recovered_count = 0;

        var index: u64 = 0;
        while (index < scenario_write_count) : (index += 1) {
            const offset = index * record_size;
            var bytes: [record_size]u8 = @splat(0);
            const read_len = try self.wal.readPositionalAll(self.io, &bytes, offset);
            if (read_len < record_size) {
                @memset(bytes[read_len..], 0);
            }

            const decoded = decodeRecord(&bytes, mode) orelse {
                try self.recorder.record("kv.recover.reject offset={} mode={s}", .{ offset, @tagName(mode) });
                break;
            };

            self.recovered[self.recovered_count] = decoded;
            self.recovered_count += 1;
            try self.recorder.record(
                "kv.recover.record offset={} key={} value={} mode={s}",
                .{ offset, decoded.key, decoded.value, @tagName(mode) },
            );
        }
    }

    fn countKey(self: *const KVStore, key: u32) u8 {
        var count: u8 = 0;
        for (self.recovered[0..self.recovered_count]) |entry| {
            if (entry.key == key) count += 1;
        }
        return count;
    }

    fn valueFor(self: *const KVStore, key: u32) ?u32 {
        for (self.recovered[0..self.recovered_count]) |entry| {
            if (entry.key == key) return entry.value;
        }
        return null;
    }
};

fn encodeRecord(bytes: *[record_size]u8, entry: Entry) void {
    var payload: Record.Payload = @splat(0);
    std.mem.writeInt(u32, &payload, entry.value, .little);
    bytes.* = Record.encode(magic, entry.key, payload);
}

fn decodeRecord(bytes: *const [record_size]u8, mode: RecoveryMode) ?Entry {
    const decoded = switch (mode) {
        .strict => Record.decodeStrict(bytes, magic),
        .buggy_accept_magic_only => Record.decodeMagicOnly(bytes, magic),
    } orelse return null;

    return .{
        .key = decoded.id,
        .value = std.mem.readInt(u32, &decoded.payload, .little),
    };
}

test "kv store: recovery passes through expectation helper" {
    try mar.expectSimPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .simulate = simulateOptions(),
        .init = init,
        .scenario = scenario,
        .checks = &checks,
    });
}

test "kv store: recovery fuzz smoke" {
    try mar.expectSimFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .seeds = 16,
        .tick_ns = tick_ns,
        .simulate = simulateOptions(),
        .init = init,
        .scenario = scenario,
        .checks = &checks,
    });
}

test "kv store: recovery window holds across probabilistic crash fault seeds" {
    try mar.expectSimFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .seeds = 32,
        .tick_ns = tick_ns,
        .simulate = simulateOptions(),
        .init = init,
        .scenario = probabilisticScenario,
        .checks = &window_checks,
    });
}

test "kv store: buggy recovery fails through expectation helper" {
    try mar.expectSimFailure(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .simulate = simulateOptions(),
        .init = init,
        .scenario = buggyScenario,
        .checks = &checks,
    });
}

test "kv store: same app code runs on simulated and real disks" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 0xC0FFEE, .tick_ns = tick_ns });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{
        .sector_size = sector_size,
        .min_latency_ns = tick_ns,
    } });
    var sim_store = try writeAndRecover(sim.env.io(), std.Io.Dir.cwd(), sim.env.recorder());
    defer sim_store.deinit();
    try expectBothRecordsRecovered(&sim_store);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var production = try mar.Production.init(.{
        .allocator = std.testing.allocator,
        .root_dir = tmp.dir,
        .io = std.testing.io,
        .disk = .{ .sector_size = sector_size },
    });
    defer production.deinit();

    const prod_env = production.env();
    var prod_store = try writeAndRecover(prod_env.io(), tmp.dir, prod_env.recorder());
    defer prod_store.deinit();
    try expectBothRecordsRecovered(&prod_store);
}
