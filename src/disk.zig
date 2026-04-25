//! Deterministic in-memory disk authority.
//!
//! This is the first no-fault disk slice: logical files, sector-aligned
//! reads/writes, deterministic latency, operation ids, and trace events.

const std = @import("std");

const clock_module = @import("clock.zig");
const World = @import("world.zig").World;
const traceField = @import("world.zig").traceField;

pub const DiskError = error{
    InvalidAlignment,
    InvalidDuration,
    InvalidPath,
    InvalidRange,
} || std.mem.Allocator.Error || @import("world.zig").TraceError;

pub const DiskOptions = struct {
    sector_size: u64 = 4096,
    min_latency_ns: clock_module.Duration = clock_module.default_tick_ns,
    latency_jitter_ns: clock_module.Duration = 0,
};

pub const Disk = struct {
    const Self = @This();

    pub const Read = struct {
        path: []const u8,
        offset: u64,
        buffer: []u8,
    };

    pub const Write = struct {
        path: []const u8,
        offset: u64,
        bytes: []const u8,
    };

    pub const Sync = struct {
        path: []const u8,
    };

    const File = struct {
        path: []u8,
        sectors: std.ArrayList(Sector) = .empty,

        fn deinit(self: *File, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            for (self.sectors.items) |*sector| sector.deinit(allocator);
            self.sectors.deinit(allocator);
            self.* = undefined;
        }
    };

    const Sector = struct {
        index: u64,
        bytes: []u8,

        fn deinit(self: *Sector, allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
            self.* = undefined;
        }
    };

    world: *World,
    options: DiskOptions,
    files: std.ArrayList(File) = .empty,
    next_op_id: u64 = 0,

    pub fn init(world: *World, options: DiskOptions) DiskError!Self {
        try validateOptions(world, options);
        return .{
            .world = world,
            .options = options,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.files.items) |*file| file.deinit(self.world.allocator);
        self.files.deinit(self.world.allocator);
        self.* = undefined;
    }

    pub fn read(self: *Self, options: Read) DiskError!void {
        try self.validatePath(options.path);
        try self.validateRange(options.offset, options.buffer.len);

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        @memset(options.buffer, 0);

        if (self.findFile(options.path)) |file| {
            try self.readSectors(file, options.offset, options.buffer);
        }

        try self.recordRangeOp(
            "disk.read",
            op_id,
            options.path,
            options.offset,
            options.buffer.len,
            "ok",
            latency_ns,
        );
    }

    pub fn write(self: *Self, options: Write) DiskError!void {
        try self.validatePath(options.path);
        try self.validateRange(options.offset, options.bytes.len);

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const file = try self.getOrCreateFile(options.path);
        try self.writeSectors(file, options.offset, options.bytes);

        try self.recordRangeOp(
            "disk.write",
            op_id,
            options.path,
            options.offset,
            options.bytes.len,
            "ok",
            latency_ns,
        );
    }

    pub fn sync(self: *Self, options: Sync) DiskError!void {
        try self.validatePath(options.path);

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();

        try self.world.recordFields("disk.sync", &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = options.path }),
            traceField("status", .{ .literal = "ok" }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
    }

    fn validateOptions(world: *World, options: DiskOptions) DiskError!void {
        if (options.sector_size == 0) return error.InvalidAlignment;
        if (options.sector_size > std.math.maxInt(usize)) return error.InvalidRange;
        const tick_ns = world.clock().tick_ns;
        if (options.min_latency_ns % tick_ns != 0) return error.InvalidDuration;
        if (options.latency_jitter_ns % tick_ns != 0) return error.InvalidDuration;
    }

    fn validatePath(_: *const Self, path: []const u8) DiskError!void {
        if (path.len == 0) return error.InvalidPath;
    }

    fn validateRange(self: *const Self, offset: u64, len: usize) DiskError!void {
        const len_u64: u64 = @intCast(len);
        if (offset % self.options.sector_size != 0) return error.InvalidAlignment;
        if (len_u64 % self.options.sector_size != 0) return error.InvalidAlignment;
        if (std.math.maxInt(u64) - offset < len_u64) return error.InvalidRange;
    }

    fn consumeOpId(self: *Self) u64 {
        const op_id = self.next_op_id;
        self.next_op_id += 1;
        return op_id;
    }

    fn advanceLatency(self: *Self) DiskError!clock_module.Duration {
        const latency_ns = try self.latency();
        if (latency_ns == 0) return latency_ns;
        if (std.math.maxInt(clock_module.Timestamp) - self.world.now() < latency_ns) {
            return error.InvalidDuration;
        }
        try self.world.runFor(latency_ns);
        return latency_ns;
    }

    fn latency(self: *Self) DiskError!clock_module.Duration {
        const jitter_ns = self.options.latency_jitter_ns;
        if (jitter_ns == 0) return self.options.min_latency_ns;

        const tick_ns = self.world.clock().tick_ns;
        const jitter_ticks = try self.world.randomIntLessThan(
            clock_module.Duration,
            jitter_ns / tick_ns + 1,
        );
        return self.options.min_latency_ns + jitter_ticks * tick_ns;
    }

    fn findFile(self: *Self, path: []const u8) ?*File {
        for (self.files.items) |*file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        return null;
    }

    fn getOrCreateFile(self: *Self, path: []const u8) DiskError!*File {
        if (self.findFile(path)) |file| return file;

        const owned_path = try self.world.allocator.dupe(u8, path);
        errdefer self.world.allocator.free(owned_path);

        try self.files.append(self.world.allocator, .{ .path = owned_path });
        return &self.files.items[self.files.items.len - 1];
    }

    fn findSector(_: *Self, file: *File, index: u64) ?*Sector {
        for (file.sectors.items) |*sector| {
            if (sector.index == index) return sector;
        }
        return null;
    }

    fn getOrCreateSector(self: *Self, file: *File, index: u64) DiskError!*Sector {
        if (self.findSector(file, index)) |sector| return sector;

        const bytes = try self.world.allocator.alloc(u8, @intCast(self.options.sector_size));
        errdefer self.world.allocator.free(bytes);
        @memset(bytes, 0);

        try file.sectors.append(self.world.allocator, .{
            .index = index,
            .bytes = bytes,
        });
        return &file.sectors.items[file.sectors.items.len - 1];
    }

    fn readSectors(self: *Self, file: *File, offset: u64, buffer: []u8) DiskError!void {
        var remaining = buffer;
        var sector_index = offset / self.options.sector_size;
        const sector_size: usize = @intCast(self.options.sector_size);

        while (remaining.len > 0) {
            if (self.findSector(file, sector_index)) |sector| {
                @memcpy(remaining[0..sector_size], sector.bytes);
            }
            remaining = remaining[sector_size..];
            sector_index += 1;
        }
    }

    fn writeSectors(self: *Self, file: *File, offset: u64, bytes: []const u8) DiskError!void {
        var remaining = bytes;
        var sector_index = offset / self.options.sector_size;
        const sector_size: usize = @intCast(self.options.sector_size);

        while (remaining.len > 0) {
            const sector = try self.getOrCreateSector(file, sector_index);
            @memcpy(sector.bytes, remaining[0..sector_size]);
            remaining = remaining[sector_size..];
            sector_index += 1;
        }
    }

    fn recordRangeOp(
        self: *Self,
        name: []const u8,
        op_id: u64,
        path: []const u8,
        offset: u64,
        len: usize,
        status: []const u8,
        latency_ns: clock_module.Duration,
    ) DiskError!void {
        try self.world.recordFields(name, &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = path }),
            traceField("offset", .{ .uint = offset }),
            traceField("len", .{ .uint = @intCast(len) }),
            traceField("status", .{ .literal = status }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
    }
};

test "disk: writes and reads sector-aligned logical files" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try Disk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.write(.{
        .path = "wal.log",
        .offset = 4,
        .bytes = "abcd",
    });

    var buffer = [_]u8{0} ** 8;
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualStrings("\x00\x00\x00\x00abcd", &buffer);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 20), world.now());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.write op=0 path=wal.log offset=4 len=4 status=ok latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=1 path=wal.log offset=0 len=8 status=ok latency_ns=10") != null);
}

test "disk: sync consumes operation ids and escapes logical paths" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var disk = try Disk.init(&world, .{});
    defer disk.deinit();

    try disk.sync(.{ .path = "dir/wal 1.log" });

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.sync op=0 path=dir/wal%201.log status=ok latency_ns=1") != null);
}

test "disk: rejects invalid paths, ranges, and latency options" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    try std.testing.expectError(
        error.InvalidAlignment,
        Disk.init(&world, .{ .sector_size = 0 }),
    );
    try std.testing.expectError(
        error.InvalidDuration,
        Disk.init(&world, .{ .min_latency_ns = 11 }),
    );

    var disk = try Disk.init(&world, .{ .sector_size = 4, .min_latency_ns = 10 });
    defer disk.deinit();

    var buffer = [_]u8{0} ** 4;
    try std.testing.expectError(error.InvalidPath, disk.read(.{
        .path = "",
        .offset = 0,
        .buffer = &buffer,
    }));
    try std.testing.expectError(error.InvalidAlignment, disk.read(.{
        .path = "wal.log",
        .offset = 1,
        .buffer = &buffer,
    }));
    try std.testing.expectError(error.InvalidAlignment, disk.write(.{
        .path = "wal.log",
        .offset = 0,
        .bytes = "abc",
    }));
}

test "disk: latency jitter is deterministic and traced" {
    var a = try World.init(std.testing.allocator, .{ .seed = 99, .tick_ns = 10 });
    defer a.deinit();
    var b = try World.init(std.testing.allocator, .{ .seed = 99, .tick_ns = 10 });
    defer b.deinit();

    var disk_a = try Disk.init(&a, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_a.deinit();
    var disk_b = try Disk.init(&b, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_b.deinit();

    try disk_a.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk_b.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });

    try std.testing.expectEqualStrings(a.traceBytes(), b.traceBytes());
    try std.testing.expect(std.mem.indexOf(u8, a.traceBytes(), "world.random_int_less_than type=u64 less_than=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, a.traceBytes(), "disk.write op=0 path=wal.log offset=0 len=4 status=ok latency_ns=") != null);
}
