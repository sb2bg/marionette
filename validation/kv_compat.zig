//! Storage compatibility validation for a small external-style KV surrogate.
//!
//! The surrogate exercises the file surface that storage engines commonly use:
//! append-only WAL records, file-content sync, compaction through atomic rename,
//! directory sync as the metadata durability boundary, WAL clear/delete, and
//! recovery that accepts a torn WAL tail but rejects damaged compacted tables.

const std = @import("std");
const mar = @import("marionette");
const wal_record = @import("examples").wal_record;

const Io = std.Io;

pub const tick_ns: mar.Duration = 1_000_000;

const max_keys = 8;
const dir_path = "/kvc";
const wal_path = "/kvc/kv.wal";
const table_path = "/kvc/kv.tab";
const tmp_path = "/kvc/kv.tab.tmp";
const Record = wal_record.Fixed(u32, 4);
const record_size = Record.record_size;
const magic: u32 = 0x4b434d31; // KCM1
const misaligned_sector_size = 7;

const Entry = struct {
    key: u32,
    value: u32,
};

const Case = mar.SimCase(CompatStore);

fn simulateOptions(sector_size: u64) mar.World.SimulateOptions {
    return .{ .disk = .{
        .sector_size = sector_size,
        .min_latency_ns = tick_ns,
    } };
}

fn initStore(sim: mar.Sim) !CompatStore {
    return try CompatStore.init(sim.env.io(), sim.env.recorder());
}

pub const lifecycle_checks = [_]mar.StateCheck(Case){
    .{ .name = "compacted table and replayed WAL recover exactly", .check = lifecycleRecoveredState },
};

pub const durable_prefix_checks = [_]mar.StateCheck(Case){
    .{ .name = "durable prefix recovers exactly", .check = durablePrefixRecoveredState },
};

pub fn fullLifecycle(case: *Case) !void {
    const store = &case.app;
    const disk = case.control().disk;

    try store.put(0, 10);
    try store.put(1, 11);
    try store.commit();
    try store.compact();
    try store.put(2, 12);
    try store.commit();
    try disk.crash();
    try disk.restart();
    try store.reopen();
}

fn writeDurablePrefix(case: *Case) !void {
    try case.app.put(0, 10);
    try case.app.put(1, 11);
    try case.app.commit();
}

/// Allowed outcome set: durable truth only. The tmp table create is pending
/// metadata; if it is lost, recovery uses the old table plus full WAL.
pub fn crashBeforeRenameLostTmp(case: *Case) !void {
    const disk = case.control().disk;

    try writeDurablePrefix(case);
    try case.app.compactUntil(.tmp_synced);
    try disk.setFaults(.{ .crash_lost_metadata_rate = .always() });
    try disk.crash();
    try disk.restart();
    try case.app.reopen();
}

/// Allowed outcome set: durable truth only. The tmp table may survive, but it
/// is still outside the rename boundary and recovery must drop it unread.
pub fn crashBeforeRenameSurvivingTmp(case: *Case) !void {
    const disk = case.control().disk;

    try writeDurablePrefix(case);
    try case.app.compactUntil(.tmp_synced);
    try disk.setFaults(.{ .crash_lost_metadata_rate = .never() });
    try disk.crash();
    try disk.restart();
    try case.app.reopen();
}

/// Allowed outcome set: durable truth only. If the rename is lost, old table
/// plus WAL recovers; if it survives, the compacted table plus old WAL
/// converges idempotently to the same state.
pub fn crashAfterRenameLostMetadata(case: *Case) !void {
    const disk = case.control().disk;

    try writeDurablePrefix(case);
    try case.app.compactUntil(.renamed);
    try disk.setFaults(.{ .crash_lost_metadata_rate = .always() });
    try disk.crash();
    try disk.restart();
    try case.app.reopen();
}

/// Allowed outcome set: durable truth only. The renamed table incarnation may
/// survive, with the uncleared WAL replaying over it idempotently.
pub fn crashAfterRenameMetadataSurvives(case: *Case) !void {
    const disk = case.control().disk;

    try writeDurablePrefix(case);
    try case.app.compactUntil(.renamed);
    try disk.setFaults(.{ .crash_lost_metadata_rate = .never() });
    try disk.crash();
    try disk.restart();
    try case.app.reopen();
}

/// Allowed outcome set: durable truth only. Torn tmp bytes are allowed damage
/// inside the recovery window because the tmp file has not been renamed into
/// durable truth and recovery never reads it.
pub fn crashAfterTornTmpWrite(case: *Case) !void {
    const disk = case.control().disk;

    try writeDurablePrefix(case);
    try case.app.compactUntil(.tmp_written);
    try disk.setFaults(.{ .crash_torn_write_rate = .always() });
    try disk.crash();
    try disk.restart();
    try case.app.reopen();
}

/// Allowed outcome set: durable truth only. Lost WAL-clear metadata leaves the
/// old WAL beside the durable compacted table; replay is idempotent.
pub fn crashDuringWalClearMetadataLost(case: *Case) !void {
    const disk = case.control().disk;

    try writeDurablePrefix(case);
    try case.app.compactUntil(.wal_cleared_unsynced);
    try disk.setFaults(.{ .crash_lost_metadata_rate = .always() });
    try disk.crash();
    try disk.restart();
    try case.app.reopen();
}

/// Allowed outcome set: durable truth only. Surviving WAL-clear metadata leaves
/// the durable compacted table and a fresh empty WAL.
pub fn crashDuringWalClearMetadataSurvives(case: *Case) !void {
    const disk = case.control().disk;

    try writeDurablePrefix(case);
    try case.app.compactUntil(.wal_cleared_unsynced);
    try disk.setFaults(.{ .crash_lost_metadata_rate = .never() });
    try disk.crash();
    try disk.restart();
    try case.app.reopen();
}

/// Allowed outcome set: durable truth only. The sweep chooses one structural
/// crash point and permits allowed damage only to pending tmp/WAL-clear work.
pub fn recoveryWindowCrashPointSweep(case: *Case) !void {
    const store = &case.app;
    const disk = case.control().disk;

    try writeDurablePrefix(case);
    try disk.setFaults(.{
        .crash_lost_metadata_rate = .percent(50),
        .crash_torn_write_rate = .percent(25),
        .crash_lost_write_rate = .percent(25),
    });

    const phase_count = @typeInfo(CompactPhase).@"enum".fields.len;
    const choice = try case.env().random.intLessThan(u8, phase_count + 1);
    if (choice == 0) {
        try store.recorder.record("kv_compat.sweep crash_point=no_compaction", .{});
    } else {
        const phase: CompactPhase = @enumFromInt(choice - 1);
        try store.recorder.record("kv_compat.sweep crash_point={s}", .{@tagName(phase)});
        try store.compactUntil(phase);
    }

    try disk.crash();
    try disk.restart();
    try store.reopen();
}

fn lifecycleRecoveredState(case: *const Case) !void {
    try expectTable(
        &case.app,
        &.{ .{ .key = 0, .value = 10 }, .{ .key = 1, .value = 11 }, .{ .key = 2, .value = 12 } },
    );
}

fn durablePrefixRecoveredState(case: *const Case) !void {
    try expectTable(
        &case.app,
        &.{ .{ .key = 0, .value = 10 }, .{ .key = 1, .value = 11 } },
    );
}

const CompactPhase = enum {
    tmp_written,
    tmp_synced,
    renamed,
    dir_synced,
    wal_cleared_unsynced,
    wal_cleared,
};

const CompatStore = struct {
    io: Io,
    recorder: mar.Recorder,
    wal: Io.File,
    wal_len: u64,
    table: [max_keys]?u32,

    fn init(io: Io, recorder: mar.Recorder) !CompatStore {
        createStoreDir(io) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        try syncDirRoot(io);

        var table_file = try openOrCreateFile(io, table_path);
        try table_file.sync(io);
        table_file.close(io);

        var store = CompatStore{
            .io = io,
            .recorder = recorder,
            .wal = try openOrCreateFile(io, wal_path),
            .wal_len = 0,
            .table = emptyTable(),
        };
        errdefer store.deinit();

        try store.wal.sync(io);
        try store.syncDirKvc();
        try store.recover();
        return store;
    }

    pub fn deinit(self: *CompatStore) void {
        self.wal.close(self.io);
    }

    fn put(self: *CompatStore, key: u32, value: u32) !void {
        std.debug.assert(key < max_keys);

        var bytes: [record_size]u8 = @splat(0);
        encodeRecord(&bytes, .{ .key = key, .value = value });

        try self.wal.writePositionalAll(self.io, &bytes, self.wal_len);
        self.wal_len += record_size;
        self.table[@intCast(key)] = value;
        try self.recorder.record("kv_compat.put key={} value={}", .{ key, value });
    }

    fn commit(self: *CompatStore) !void {
        try self.wal.sync(self.io);
        try self.recorder.record("kv_compat.commit wal_len={}", .{self.wal_len});
    }

    fn reopen(self: *CompatStore) !void {
        self.wal.close(self.io);
        self.wal = try openOrCreateFile(self.io, wal_path);
        try self.recover();
    }

    fn compact(self: *CompatStore) !void {
        try self.compactUntil(.wal_cleared);
    }

    fn compactUntil(self: *CompatStore, phase: CompactPhase) !void {
        var tmp = try Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true });
        var tmp_closed = false;
        defer if (!tmp_closed) tmp.close(self.io);

        var offset: u64 = 0;
        for (self.table, 0..) |maybe_value, key| {
            const value = maybe_value orelse continue;
            var bytes: [record_size]u8 = @splat(0);
            encodeRecord(&bytes, .{ .key = @intCast(key), .value = value });
            try tmp.writePositionalAll(self.io, &bytes, offset);
            offset += record_size;
        }
        try self.recorder.record("kv_compat.compact phase=tmp_written", .{});
        if (phase == .tmp_written) return;

        try tmp.sync(self.io);
        try self.recorder.record("kv_compat.compact phase=tmp_synced", .{});
        tmp.close(self.io);
        tmp_closed = true;
        if (phase == .tmp_synced) return;

        try Io.Dir.cwd().rename(tmp_path, Io.Dir.cwd(), table_path, self.io);
        try self.recorder.record("kv_compat.compact phase=renamed", .{});
        if (phase == .renamed) return;

        try self.syncDirKvc();
        try self.recorder.record("kv_compat.compact phase=dir_synced", .{});
        if (phase == .dir_synced) return;

        self.wal.close(self.io);
        try Io.Dir.cwd().deleteFile(self.io, wal_path);
        self.wal = try Io.Dir.cwd().createFile(self.io, wal_path, .{ .read = true });
        try self.wal.sync(self.io);
        self.wal_len = 0;
        try self.recorder.record("kv_compat.compact phase=wal_cleared_unsynced", .{});
        if (phase == .wal_cleared_unsynced) return;

        try self.syncDirKvc();
        try self.recorder.record("kv_compat.compact phase=wal_cleared", .{});
    }

    fn recover(self: *CompatStore) !void {
        self.table = emptyTable();

        const table_records = try self.recoverTable();
        const wal_records = try self.recoverWal();

        if (deleteIfExists(self.io, tmp_path)) |deleted| {
            if (deleted) {
                try self.syncDirKvc();
                try self.recorder.record("kv_compat.recover dropped_tmp=true", .{});
            }
        } else |err| return err;

        try self.recorder.record(
            "kv_compat.recover table_records={} wal_records={}",
            .{ table_records, wal_records },
        );
    }

    fn recoverTable(self: *CompatStore) !usize {
        var file = Io.Dir.cwd().openFile(self.io, table_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer file.close(self.io);

        var count: usize = 0;
        var offset: u64 = 0;
        while (true) : (offset += record_size) {
            var bytes: [record_size]u8 = @splat(0);
            const read_len = try file.readPositionalAll(self.io, &bytes, offset);
            if (read_len == 0) break;
            if (read_len < record_size) return error.DamagedTableRecord;
            const entry = decodeRecord(&bytes) orelse return error.DamagedTableRecord;
            if (entry.key >= max_keys) return error.DamagedTableRecord;
            self.table[@intCast(entry.key)] = entry.value;
            count += 1;
        }
        return count;
    }

    fn recoverWal(self: *CompatStore) !usize {
        var count: usize = 0;
        var offset: u64 = 0;
        while (true) {
            var bytes: [record_size]u8 = @splat(0);
            const read_len = try self.wal.readPositionalAll(self.io, &bytes, offset);
            if (read_len < record_size) break;
            const entry = decodeRecord(&bytes) orelse break;
            if (entry.key >= max_keys) break;
            self.table[@intCast(entry.key)] = entry.value;
            count += 1;
            offset += record_size;
        }
        self.wal_len = offset;
        return count;
    }

    fn syncDirKvc(self: *CompatStore) !void {
        var directory_file = try Io.Dir.openFileAbsolute(self.io, dir_path, .{ .allow_directory = true });
        defer directory_file.close(self.io);
        try directory_file.sync(self.io);
    }
};

fn createStoreDir(io: Io) !void {
    try Io.Dir.createDirAbsolute(io, dir_path, .default_dir);
}

fn syncDirRoot(io: Io) !void {
    var directory_file = try Io.Dir.openFileAbsolute(io, "/", .{ .allow_directory = true });
    defer directory_file.close(io);
    try directory_file.sync(io);
}

fn openOrCreateFile(io: Io, path: []const u8) !Io.File {
    return Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => Io.Dir.cwd().createFile(io, path, .{ .read = true }),
        else => err,
    };
}

fn deleteIfExists(io: Io, path: []const u8) !bool {
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn emptyTable() [max_keys]?u32 {
    return [_]?u32{null} ** max_keys;
}

fn encodeRecord(bytes: *[record_size]u8, entry: Entry) void {
    var payload: Record.Payload = @splat(0);
    std.mem.writeInt(u32, &payload, entry.value, .little);
    bytes.* = Record.encode(magic, entry.key, payload);
}

fn decodeRecord(bytes: *const [record_size]u8) ?Entry {
    const decoded = Record.decodeStrict(bytes, magic) orelse return null;
    return .{
        .key = decoded.id,
        .value = std.mem.readInt(u32, &decoded.payload, .little),
    };
}

fn expectTable(store: *const CompatStore, expected: []const Entry) !void {
    var seen: [max_keys]bool = @splat(false);
    for (expected) |entry| {
        std.debug.assert(entry.key < max_keys);
        const index: usize = @intCast(entry.key);
        seen[index] = true;
        try std.testing.expectEqual(@as(?u32, entry.value), store.table[index]);
    }
    for (store.table, 0..) |maybe_value, key| {
        if (!seen[key]) try std.testing.expectEqual(@as(?u32, null), maybe_value);
    }
}

test "kv compat: full lifecycle survives clean crash and recovery" {
    try mar.expectSimPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .simulate = simulateOptions(record_size),
        .init = initStore,
        .scenario = fullLifecycle,
        .checks = &lifecycle_checks,
    });
}

test "kv compat: lifecycle trace records the compaction phases" {
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .name = "kv-compat-lifecycle",
        .simulate = simulateOptions(record_size),
        .init = initStore,
        .scenario = fullLifecycle,
        .checks = &lifecycle_checks,
    });
    defer report.deinit();

    switch (report) {
        .passed => |*passed| {
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "kv_compat.compact phase=renamed") != null);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "kv_compat.recover") != null);
        },
        .failed => return error.KvCompatLifecycleFailed,
    }
}

fn expectCrashScenarioPass(
    comptime scenario: fn (*Case) anyerror!void,
) !void {
    try mar.expectSimPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .simulate = simulateOptions(record_size),
        .init = initStore,
        .scenario = scenario,
        .checks = &durable_prefix_checks,
    });
}

fn runCrashScenarioReport(
    comptime scenario: fn (*Case) anyerror!void,
) !mar.RunReport {
    return mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .name = "kv-compat-crash-point",
        .simulate = simulateOptions(record_size),
        .init = initStore,
        .scenario = scenario,
        .checks = &durable_prefix_checks,
    });
}

test "kv compat: crash before compaction rename preserves durable truth" {
    try expectCrashScenarioPass(crashBeforeRenameLostTmp);
    try expectCrashScenarioPass(crashBeforeRenameSurvivingTmp);

    var report = try runCrashScenarioReport(crashBeforeRenameSurvivingTmp);
    defer report.deinit();
    switch (report) {
        .passed => |*passed| {
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "kv_compat.recover dropped_tmp=true") != null);
        },
        .failed => return error.KvCompatCrashBeforeRenameFailed,
    }
}

test "kv compat: crash between rename and dir sync recovers either incarnation" {
    try expectCrashScenarioPass(crashAfterRenameLostMetadata);
    try expectCrashScenarioPass(crashAfterRenameMetadataSurvives);
}

test "kv compat: torn tmp write never damages durable truth" {
    try expectCrashScenarioPass(crashAfterTornTmpWrite);
}

test "kv compat: crash during wal clear converges after replay" {
    try expectCrashScenarioPass(crashDuringWalClearMetadataLost);
    try expectCrashScenarioPass(crashDuringWalClearMetadataSurvives);
}

test "kv compat: recovery window holds across crash-point fuzz seeds" {
    try mar.expectSimFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .seeds = 32,
        .tick_ns = tick_ns,
        .simulate = simulateOptions(record_size),
        .init = initStore,
        .scenario = recoveryWindowCrashPointSweep,
        .checks = &durable_prefix_checks,
    });
}

test "kv compat: recovery window holds across misaligned crash-point fuzz seeds" {
    try mar.expectSimFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .seeds = 32,
        .tick_ns = tick_ns,
        .simulate = simulateOptions(misaligned_sector_size),
        .init = initStore,
        .scenario = recoveryWindowCrashPointSweep,
        .checks = &durable_prefix_checks,
    });
}
