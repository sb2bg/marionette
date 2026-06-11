//! Marionette example: WAL recovery under crash + corruption.
//!
//! - `Harness` holds simulator state that outlives one scenario.
//! - `scenario` drives writes, faults, crash, restart, and recovery.
//! - `checks` assert the invariant after the scenario runs.
//! - `expectPass` / `expectFuzz` / `expectFailure` are the runners.

const std = @import("std");
const mar = @import("marionette");

pub const tick_ns: mar.Duration = 1_000_000;
const wal_path = "kv.wal";
const record_size = 16;
const scenario_write_count = 2;
const magic: u32 = 0x4d4b5631;
const committed_key: u32 = 1;
const committed_value: u32 = 41;
const volatile_key: u32 = 2;
const volatile_value: u32 = 99;

pub const checks = [_]mar.StateCheck(Harness){
    .{ .name = "synced records recover and unsynced records are rejected", .check = recoveredStateIsSafe },
};

pub fn scenario(harness: *Harness) !void {
    try harness.store.put(committed_key, committed_value, .sync);
    try harness.control.disk.setFaults(.{ .crash_lost_write_rate = .always() });
    try harness.store.put(volatile_key, volatile_value, .no_sync);
    try harness.control.disk.crash();
    try harness.control.disk.restart();
    try harness.store.reopen();
    try harness.control.disk.corruptSector(wal_path, record_size);
    try harness.store.recover(.strict);
}

pub fn buggyScenario(harness: *Harness) !void {
    try harness.store.put(committed_key, committed_value, .sync);
    try harness.control.disk.setFaults(.{ .crash_torn_write_rate = .always() });
    try harness.store.put(volatile_key, volatile_value, .no_sync);
    try harness.control.disk.crash();
    try harness.control.disk.restart();
    try harness.store.reopen();
    try harness.store.recover(.buggy_accept_magic_only);
}

fn recoveredStateIsSafe(harness: *const Harness) !void {
    const store = &harness.store;

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

pub const Harness = struct {
    store: KVStore,
    control: mar.Control,

    pub fn init(world: *mar.World) !Harness {
        const sim = try world.simulate(.{ .disk = .{
            .sector_size = record_size,
            .min_latency_ns = tick_ns,
        } });

        return .{
            .store = try KVStore.init(sim.env.io(), std.Io.Dir.cwd(), sim.env.recorder()),
            .control = sim.control,
        };
    }

    pub fn deinit(self: *Harness) void {
        self.store.deinit();
    }
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

    fn deinit(self: *KVStore) void {
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
    putU32(bytes[0..4], magic);
    putU32(bytes[4..8], entry.key);
    putU32(bytes[8..12], entry.value);
    putU32(bytes[12..16], checksum(entry.key, entry.value));
}

fn decodeRecord(bytes: *const [record_size]u8, mode: RecoveryMode) ?Entry {
    if (readU32(bytes[0..4]) != magic) return null;

    const entry: Entry = .{
        .key = readU32(bytes[4..8]),
        .value = readU32(bytes[8..12]),
    };

    switch (mode) {
        .strict => {
            if (readU32(bytes[12..16]) != checksum(entry.key, entry.value)) return null;
        },
        .buggy_accept_magic_only => {},
    }

    return entry;
}

fn checksum(key: u32, value: u32) u32 {
    return magic ^ std.math.rotl(u32, key, 7) ^ std.math.rotl(u32, value, 17) ^ 0xa5a5_5a5a;
}

fn putU32(bytes: []u8, value: u32) void {
    std.debug.assert(bytes.len == 4);
    bytes[0] = @as(u8, @truncate(value));
    bytes[1] = @as(u8, @truncate(value >> 8));
    bytes[2] = @as(u8, @truncate(value >> 16));
    bytes[3] = @as(u8, @truncate(value >> 24));
}

fn readU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len == 4);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

test "kv store: recovery passes through expectation helper" {
    try mar.expectPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .init = Harness.init,
        .deinit = Harness.deinit,
        .scenario = scenario,
        .checks = &checks,
    });
}

test "kv store: recovery fuzz smoke" {
    try mar.expectFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .seeds = 16,
        .tick_ns = tick_ns,
        .init = Harness.init,
        .deinit = Harness.deinit,
        .scenario = scenario,
        .checks = &checks,
    });
}

test "kv store: buggy recovery fails through expectation helper" {
    try mar.expectFailure(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .init = Harness.init,
        .deinit = Harness.deinit,
        .scenario = buggyScenario,
        .checks = &checks,
    });
}

test "kv store: same app code runs on simulated and real disks" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 0xC0FFEE, .tick_ns = tick_ns });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{
        .sector_size = record_size,
        .min_latency_ns = tick_ns,
    } });
    var sim_store = try writeAndRecover(sim.env.io(), std.Io.Dir.cwd(), sim.env.recorder());
    defer sim_store.deinit();
    try expectBothRecordsRecovered(&sim_store);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var production = try mar.Production.init(.{
        .root_dir = tmp.dir,
        .io = std.testing.io,
        .disk = .{ .sector_size = record_size },
    });
    defer production.deinit();

    const prod_env = production.env();
    var prod_store = try writeAndRecover(prod_env.io(), tmp.dir, prod_env.recorder());
    defer prod_store.deinit();
    try expectBothRecordsRecovered(&prod_store);
}
