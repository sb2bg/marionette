//! Tiny disk-backed KV recovery showcase.
//!
//! This is not a production KV store. It is a compact durability example for
//! `mar.Disk`: fixed-size WAL records, sync as the durability boundary,
//! crash/restart, corrupt reads, and a deliberately buggy recovery path.

const std = @import("std");
const mar = @import("marionette");

const ns_per_ms: mar.Duration = 1_000_000;
const wal_path = "kv.wal";
const record_size = 16;
const max_records = 2;
const magic: u32 = 0x4d4b5631;

const Profile = struct {
    record_size: u64,
    committed_key: u64,
    committed_value: u64,
    volatile_key: u64,
    volatile_value: u64,
};

const profile: Profile = .{
    .record_size = record_size,
    .committed_key = 1,
    .committed_value = 41,
    .volatile_key = 2,
    .volatile_value = 99,
};

const tags = [_][]const u8{
    "example:kv_store",
    "scenario:wal_recovery",
};

const buggy_tags = [_][]const u8{
    "example:kv_store",
    "scenario:bug",
    "bug:accept_torn_record",
};

const attributes = mar.runAttributesFrom(profile);

const checks = [_]mar.StateCheck(Store){
    .{ .name = "synced records recover and unsynced records are rejected", .check = recoveredStateIsSafe },
};

/// Run the correct WAL recovery scenario and return an owned trace.
pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var report = try mar.runWithState(
        allocator,
        .{
            .seed = seed,
            .tick_ns = ns_per_ms,
            .profile_name = "kv-store-wal-recovery",
            .tags = &tags,
            .attributes = &attributes,
        },
        Store,
        Store.init,
        scenario,
        &checks,
    );
    defer report.deinit();

    switch (report) {
        .passed => |*passed| return passed.takeTrace(),
        .failed => |failure| {
            failure.print();
            return error.KVStoreScenarioFailed;
        },
    }
}

/// Run a deliberately buggy recovery scenario.
pub fn runBuggyScenario(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return mar.runWithState(
        allocator,
        .{
            .seed = seed,
            .tick_ns = ns_per_ms,
            .profile_name = "kv-store-wal-recovery-bug",
            .tags = &buggy_tags,
            .attributes = &attributes,
        },
        Store,
        Store.init,
        buggyScenario,
        &checks,
    );
}

fn scenario(store: *Store) !void {
    defer store.disk.deinit();

    try store.put(profile.committed_key, profile.committed_value, .sync);
    try store.disk.setFaults(.{ .crash_lost_write_rate = .always() });
    try store.put(profile.volatile_key, profile.volatile_value, .no_sync);
    try store.disk.crash(.{});
    try store.disk.restart(.{});
    try store.disk.corruptSector(wal_path, record_size);
    try store.recover(.strict);
}

fn buggyScenario(store: *Store) !void {
    defer store.disk.deinit();

    try store.put(profile.committed_key, profile.committed_value, .sync);
    try store.disk.setFaults(.{ .crash_torn_write_rate = .always() });
    try store.put(profile.volatile_key, profile.volatile_value, .no_sync);
    try store.disk.crash(.{});
    try store.disk.restart(.{});
    try store.recover(.buggy_accept_magic_only);
}

fn recoveredStateIsSafe(store: *const Store) !void {
    const committed_key: u32 = @intCast(profile.committed_key);
    const committed_value: u32 = @intCast(profile.committed_value);
    const volatile_key: u32 = @intCast(profile.volatile_key);

    if (store.countKey(committed_key) != 1 or store.valueFor(committed_key) != committed_value) {
        try store.env.record("kv.invariant_violation reason=committed_missing_or_wrong", .{});
        return error.CommittedRecordNotRecovered;
    }

    if (store.countKey(volatile_key) != 0) {
        try store.env.record("kv.invariant_violation reason=unsynced_record_recovered", .{});
        return error.UnsyncedRecordRecovered;
    }

    try store.env.record(
        "kv.check recovery=ok committed_key={} committed_value={} recovered_records={}",
        .{ committed_key, committed_value, store.recovered_count },
    );
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

const Store = struct {
    env: mar.SimulationEnv,
    disk: mar.Disk,
    next_offset: u64 = 0,
    recovered: [max_records]Entry = undefined,
    recovered_count: u8 = 0,

    fn init(world: *mar.World) Store {
        return .{
            .env = mar.SimulationEnv.init(world),
            .disk = mar.Disk.init(world, .{
                .sector_size = record_size,
                .min_latency_ns = ns_per_ms,
            }) catch unreachable,
        };
    }

    fn put(self: *Store, key_value: u64, value_value: u64, sync_mode: SyncMode) !void {
        const key: u32 = @intCast(key_value);
        const value: u32 = @intCast(value_value);

        var bytes = [_]u8{0} ** record_size;
        encodeRecord(&bytes, .{ .key = key, .value = value });

        const offset = self.next_offset;
        try self.disk.write(.{
            .path = wal_path,
            .offset = offset,
            .bytes = &bytes,
        });
        self.next_offset += record_size;

        if (sync_mode == .sync) {
            try self.disk.sync(.{ .path = wal_path });
        }

        try self.env.record(
            "kv.put key={} value={} offset={} sync={s}",
            .{ key, value, offset, @tagName(sync_mode) },
        );
    }

    fn recover(self: *Store, mode: RecoveryMode) !void {
        self.recovered_count = 0;

        var index: u64 = 0;
        while (index < max_records) : (index += 1) {
            const offset = index * record_size;
            var bytes = [_]u8{0} ** record_size;
            try self.disk.read(.{
                .path = wal_path,
                .offset = offset,
                .buffer = &bytes,
            });

            const decoded = decodeRecord(&bytes, mode) orelse {
                try self.env.record("kv.recover.reject offset={} mode={s}", .{ offset, @tagName(mode) });
                break;
            };

            self.recovered[self.recovered_count] = decoded;
            self.recovered_count += 1;
            try self.env.record(
                "kv.recover.record offset={} key={} value={} mode={s}",
                .{ offset, decoded.key, decoded.value, @tagName(mode) },
            );
        }
    }

    fn countKey(self: *const Store, key: u32) u8 {
        var count: u8 = 0;
        for (self.recovered[0..self.recovered_count]) |entry| {
            if (entry.key == key) count += 1;
        }
        return count;
    }

    fn valueFor(self: *const Store, key: u32) ?u32 {
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
