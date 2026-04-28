//! Deterministic in-memory disk simulator and disk capabilities.
//!
//! Logical files, sector-aligned reads/writes, deterministic latency,
//! operation ids, trace events, replayable faults, and crash/restart.

const std = @import("std");

const clock_module = @import("clock.zig");
const env_module = @import("env.zig");
const World = @import("world.zig").World;
const traceField = @import("world.zig").traceField;

pub const DiskError = error{
    DiskUnavailable,
    InvalidAlignment,
    InvalidDuration,
    InvalidPath,
    InvalidRate,
    InvalidRange,
    DiskCrashed,
    ReadError,
    WriteError,
} || std.mem.Allocator.Error || @import("world.zig").TraceError;

pub const DiskOptions = struct {
    sector_size: u64 = 4096,
    min_latency_ns: ?clock_module.Duration = null,
    latency_jitter_ns: clock_module.Duration = 0,
};

pub const DiskFaultOptions = struct {
    read_error_rate: env_module.BuggifyRate = .never(),
    write_error_rate: env_module.BuggifyRate = .never(),
    corrupt_read_rate: env_module.BuggifyRate = .never(),
    crash_lost_write_rate: env_module.BuggifyRate = .never(),
    crash_torn_write_rate: env_module.BuggifyRate = .never(),
};

pub const Disk = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Read = DiskRead;
    pub const Write = DiskWrite;
    pub const Sync = DiskSync;

    pub const VTable = struct {
        read: *const fn (*anyopaque, Read) DiskError!void,
        write: *const fn (*anyopaque, Write) DiskError!void,
        sync: *const fn (*anyopaque, Sync) DiskError!void,
    };

    pub fn read(self: Disk, options: Read) DiskError!void {
        try self.vtable.read(self.ptr, options);
    }

    pub fn write(self: Disk, options: Write) DiskError!void {
        try self.vtable.write(self.ptr, options);
    }

    pub fn sync(self: Disk, options: Sync) DiskError!void {
        try self.vtable.sync(self.ptr, options);
    }

    pub fn unavailable() Disk {
        return .{ .ptr = &unavailable_disk_ctx, .vtable = &unavailable_disk_vtable };
    }
};

var unavailable_disk_ctx: u8 = 0;

const unavailable_disk_vtable: Disk.VTable = .{
    .read = unavailableRead,
    .write = unavailableWrite,
    .sync = unavailableSync,
};

fn unavailableRead(_: *anyopaque, _: Disk.Read) DiskError!void {
    return error.DiskUnavailable;
}

fn unavailableWrite(_: *anyopaque, _: Disk.Write) DiskError!void {
    return error.DiskUnavailable;
}

fn unavailableSync(_: *anyopaque, _: Disk.Sync) DiskError!void {
    return error.DiskUnavailable;
}

pub const DiskControl = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        set_faults: *const fn (*anyopaque, DiskFaultOptions) DiskError!void,
        corrupt_sector: *const fn (*anyopaque, []const u8, u64) DiskError!void,
        crash: *const fn (*anyopaque) DiskError!void,
        restart: *const fn (*anyopaque) DiskError!void,
        disk: *const fn (*anyopaque) Disk,
    };

    pub fn setFaults(self: DiskControl, faults: DiskFaultOptions) DiskError!void {
        try self.vtable.set_faults(self.ptr, faults);
    }

    pub fn corruptSector(self: DiskControl, path: []const u8, offset: u64) DiskError!void {
        try self.vtable.corrupt_sector(self.ptr, path, offset);
    }

    pub fn crash(self: DiskControl) DiskError!void {
        try self.vtable.crash(self.ptr);
    }

    pub fn restart(self: DiskControl) DiskError!void {
        try self.vtable.restart(self.ptr);
    }

    pub fn disk(self: DiskControl) Disk {
        return self.vtable.disk(self.ptr);
    }
};

pub const DiskRead = struct {
    path: []const u8,
    offset: u64,
    buffer: []u8,
};

pub const DiskWrite = struct {
    path: []const u8,
    offset: u64,
    bytes: []const u8,
};

pub const DiskSync = struct {
    path: []const u8,
};

pub const DiskCrash = struct {};

pub const DiskRestart = struct {};

/// Production adapter from a real root directory into Marionette's app-facing
/// `Disk` capability.
///
/// The `io` field is the host I/O backend used to execute filesystem calls. It
/// is not the simulation hook: deterministic tests should use `SimDisk`
/// directly through `Env.disk`, with fault/crash authority kept on
/// `DiskControl`.
pub const RealDisk = struct {
    const Self = @This();

    pub const Options = struct {
        sector_size: u64 = 4096,
    };

    /// Root directory that all disk paths are resolved beneath.
    root: std.Io.Dir,
    /// Host I/O backend for real filesystem operations.
    io: std.Io,
    options: Options,

    /// Build a production disk adapter. `root` remains owned by the caller and
    /// must outlive this `RealDisk`.
    pub fn init(root: std.Io.Dir, io: std.Io, options: Options) DiskError!Self {
        if (options.sector_size == 0) return error.InvalidAlignment;
        if (options.sector_size > std.math.maxInt(usize)) return error.InvalidRange;
        return .{
            .root = root,
            .io = io,
            .options = options,
        };
    }

    pub fn disk(self: *Self) Disk {
        return .{ .ptr = self, .vtable = &disk_vtable };
    }

    pub fn deinit(_: *Self) void {}

    fn read(self: *Self, options: Disk.Read) DiskError!void {
        try self.validatePath(options.path);
        try self.validateRange(options.offset, options.buffer.len);

        @memset(options.buffer, 0);

        var file = self.root.openFile(self.io, options.path, .{
            .mode = .read_only,
            .allow_directory = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return mapOpenReadError(err),
        };
        defer file.close(self.io);

        const read_len = file.readPositionalAll(self.io, options.buffer, options.offset) catch |err| {
            return mapReadError(err);
        };
        if (read_len < options.buffer.len) {
            @memset(options.buffer[read_len..], 0);
        }
    }

    fn write(self: *Self, options: Disk.Write) DiskError!void {
        try self.validatePath(options.path);
        try self.validateRange(options.offset, options.bytes.len);
        try self.ensureParentDirs(options.path);

        var file = self.root.createFile(self.io, options.path, .{
            .read = true,
            .truncate = false,
        }) catch |err| {
            return mapOpenWriteError(err);
        };
        defer file.close(self.io);

        file.writePositionalAll(self.io, options.bytes, options.offset) catch |err| {
            return mapWriteError(err);
        };
    }

    fn sync(self: *Self, options: Disk.Sync) DiskError!void {
        try self.validatePath(options.path);

        var file = self.root.openFile(self.io, options.path, .{
            .mode = .read_write,
            .allow_directory = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return mapOpenWriteError(err),
        };
        defer file.close(self.io);

        file.sync(self.io) catch |err| {
            return mapSyncError(err);
        };
    }

    fn ensureParentDirs(self: *Self, path: []const u8) DiskError!void {
        const parent = std.fs.path.dirname(path) orelse return;
        if (parent.len == 0) return;
        self.root.createDirPath(self.io, parent) catch |err| {
            return mapCreateDirError(err);
        };
    }

    fn validatePath(_: *const Self, path: []const u8) DiskError!void {
        if (path.len == 0) return error.InvalidPath;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        if (std.fs.path.isAbsolute(path)) return error.InvalidPath;
        var iterator = std.mem.splitAny(u8, path, "/\\");
        while (iterator.next()) |component| {
            if (std.mem.eql(u8, component, "..")) return error.InvalidPath;
        }
    }

    fn validateRange(self: *const Self, offset: u64, len: usize) DiskError!void {
        const len_u64: u64 = @intCast(len);
        if (offset % self.options.sector_size != 0) return error.InvalidAlignment;
        if (len_u64 % self.options.sector_size != 0) return error.InvalidAlignment;
        if (std.math.maxInt(u64) - offset < len_u64) return error.InvalidRange;
    }

    const disk_vtable: Disk.VTable = .{
        .read = diskRead,
        .write = diskWrite,
        .sync = diskSync,
    };

    fn fromOpaque(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }

    fn diskRead(ptr: *anyopaque, options: Disk.Read) DiskError!void {
        try fromOpaque(ptr).read(options);
    }

    fn diskWrite(ptr: *anyopaque, options: Disk.Write) DiskError!void {
        try fromOpaque(ptr).write(options);
    }

    fn diskSync(ptr: *anyopaque, options: Disk.Sync) DiskError!void {
        try fromOpaque(ptr).sync(options);
    }
};

fn mapOpenReadError(err: std.Io.File.OpenError) DiskError {
    return switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        error.IsDir,
        error.NotDir,
        error.SymLinkLoop,
        => error.InvalidPath,
        else => error.ReadError,
    };
}

fn mapOpenWriteError(err: std.Io.File.OpenError) DiskError {
    return switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        error.IsDir,
        error.NotDir,
        error.SymLinkLoop,
        => error.InvalidPath,
        else => error.WriteError,
    };
}

fn mapReadError(err: std.Io.File.ReadPositionalError) DiskError {
    return switch (err) {
        error.AccessDenied,
        error.NotOpenForReading,
        error.IsDir,
        error.Unseekable,
        => error.InvalidPath,
        else => error.ReadError,
    };
}

fn mapWriteError(err: std.Io.File.WritePositionalError) DiskError {
    return switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        error.NotOpenForWriting,
        error.Unseekable,
        => error.InvalidPath,
        else => error.WriteError,
    };
}

fn mapSyncError(err: std.Io.File.SyncError) DiskError {
    return switch (err) {
        error.AccessDenied => error.InvalidPath,
        else => error.WriteError,
    };
}

fn mapCreateDirError(err: std.Io.Dir.CreateDirPathError) DiskError {
    return switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        error.NotDir,
        error.SymLinkLoop,
        => error.InvalidPath,
        else => error.WriteError,
    };
}

pub const SimDisk = struct {
    const Self = @This();
    const ResolvedOptions = struct {
        sector_size: u64,
        min_latency_ns: clock_module.Duration,
        latency_jitter_ns: clock_module.Duration,
    };

    pub const Read = DiskRead;
    pub const Write = DiskWrite;
    pub const Sync = DiskSync;
    pub const Crash = DiskCrash;
    pub const Restart = DiskRestart;

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
        corrupt: bool = false,

        fn deinit(self: *Sector, allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
            self.* = undefined;
        }
    };

    const PendingWrite = struct {
        op_id: u64,
        path: []u8,
        offset: u64,
        bytes: []u8,

        fn deinit(self: *PendingWrite, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            allocator.free(self.bytes);
            self.* = undefined;
        }
    };

    world: *World,
    options: ResolvedOptions,
    faults: DiskFaultOptions = .{},
    files: std.ArrayList(File) = .empty,
    pending_writes: std.ArrayList(PendingWrite) = .empty,
    next_op_id: u64 = 0,
    crashed: bool = false,

    pub fn init(world: *World, options: DiskOptions) DiskError!Self {
        const resolved_options = try resolveOptions(world, options);
        return .{
            .world = world,
            .options = resolved_options,
        };
    }

    pub fn disk(self: *Self) Disk {
        return .{ .ptr = self, .vtable = &disk_vtable };
    }

    pub fn control(self: *Self) DiskControl {
        return .{ .ptr = self, .vtable = &control_vtable };
    }

    pub fn deinit(self: *Self) void {
        for (self.files.items) |*file| file.deinit(self.world.allocator);
        self.files.deinit(self.world.allocator);
        for (self.pending_writes.items) |*pending| pending.deinit(self.world.allocator);
        self.pending_writes.deinit(self.world.allocator);
        self.* = undefined;
    }

    fn setFaults(self: *Self, faults: DiskFaultOptions) DiskError!void {
        try validateFaultRate(faults.read_error_rate);
        try validateFaultRate(faults.write_error_rate);
        try validateFaultRate(faults.corrupt_read_rate);
        try validateFaultRate(faults.crash_lost_write_rate);
        try validateFaultRate(faults.crash_torn_write_rate);
        self.faults = faults;
    }

    fn corruptSector(self: *Self, path: []const u8, offset: u64) DiskError!void {
        try self.validatePath(path);
        try self.validateRange(offset, @intCast(self.options.sector_size));

        const file = try self.getOrCreateFile(path);
        const sector = try self.getOrCreateSector(file, offset / self.options.sector_size);
        sector.corrupt = true;

        try self.world.recordFields("disk.fault", &.{
            traceField("path", .{ .text = path }),
            traceField("offset", .{ .uint = offset }),
            traceField("kind", .{ .literal = "scripted_corruption" }),
        });
    }

    fn read(self: *Self, options: Read) DiskError!void {
        try self.validatePath(options.path);
        try self.validateRange(options.offset, options.buffer.len);
        try self.ensureRunning();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();

        if (try self.rollFault(op_id, options.path, "read_error", self.faults.read_error_rate)) {
            try self.recordRangeOp(
                "disk.read",
                op_id,
                options.path,
                options.offset,
                options.buffer.len,
                "io_error",
                latency_ns,
            );
            return error.ReadError;
        }

        @memset(options.buffer, 0);

        if (self.findFile(options.path)) |file| {
            try self.readSectors(file, options.offset, options.buffer);
        }
        self.overlayPendingWrites(options.path, options.offset, options.buffer);

        const corrupt = self.rangeHasCorruption(options.path, options.offset, options.buffer.len) or
            try self.rollFault(op_id, options.path, "corrupt_read", self.faults.corrupt_read_rate);
        const status = if (corrupt) "corrupt" else "ok";
        if (corrupt and options.buffer.len > 0) {
            options.buffer[0] ^= 0xff;
        }

        try self.recordRangeOp(
            "disk.read",
            op_id,
            options.path,
            options.offset,
            options.buffer.len,
            status,
            latency_ns,
        );
    }

    fn write(self: *Self, options: Write) DiskError!void {
        try self.validatePath(options.path);
        try self.validateRange(options.offset, options.bytes.len);
        try self.ensureRunning();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        if (try self.rollFault(op_id, options.path, "write_error", self.faults.write_error_rate)) {
            try self.recordRangeOp(
                "disk.write",
                op_id,
                options.path,
                options.offset,
                options.bytes.len,
                "io_error",
                latency_ns,
            );
            return error.WriteError;
        }

        try self.appendPendingWrite(op_id, options.path, options.offset, options.bytes);

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

    fn sync(self: *Self, options: Sync) DiskError!void {
        try self.validatePath(options.path);
        try self.ensureRunning();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const committed = try self.commitPendingWrites(options.path);

        try self.world.recordFields("disk.sync", &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = options.path }),
            traceField("status", .{ .literal = "ok" }),
            traceField("committed_writes", .{ .uint = committed }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
    }

    fn crash(self: *Self, _: Crash) DiskError!void {
        try self.ensureRunning();

        const pending_count = self.pending_writes.items.len;
        var landed: u64 = 0;
        var lost: u64 = 0;
        var torn: u64 = 0;

        for (self.pending_writes.items) |*pending| {
            if (try self.rollFault(
                pending.op_id,
                pending.path,
                "crash_lost_write",
                self.faults.crash_lost_write_rate,
            )) {
                lost += 1;
                try self.recordCrashWrite(pending, "lost");
                continue;
            }

            if (try self.rollFault(
                pending.op_id,
                pending.path,
                "crash_torn_write",
                self.faults.crash_torn_write_rate,
            )) {
                try self.applyTornWrite(pending);
                torn += 1;
                try self.recordCrashWrite(pending, "torn");
                continue;
            }

            try self.applyFullWrite(pending);
            landed += 1;
            try self.recordCrashWrite(pending, "landed");
        }
        self.clearPendingWrites();
        self.crashed = true;

        try self.world.recordFields("disk.crash", &.{
            traceField("pending_writes", .{ .uint = @intCast(pending_count) }),
            traceField("landed", .{ .uint = landed }),
            traceField("lost", .{ .uint = lost }),
            traceField("torn", .{ .uint = torn }),
        });
    }

    fn restart(self: *Self, _: Restart) DiskError!void {
        self.crashed = false;
        try self.world.recordFields("disk.restart", &.{
            traceField("status", .{ .literal = "ok" }),
        });
    }

    fn resolveOptions(world: *World, options: DiskOptions) DiskError!ResolvedOptions {
        if (options.sector_size == 0) return error.InvalidAlignment;
        if (options.sector_size > std.math.maxInt(usize)) return error.InvalidRange;
        const min_latency_ns = options.min_latency_ns orelse world.clock().tick_ns;
        const tick_ns = world.clock().tick_ns;
        if (min_latency_ns % tick_ns != 0) return error.InvalidDuration;
        if (options.latency_jitter_ns % tick_ns != 0) return error.InvalidDuration;
        return .{
            .sector_size = options.sector_size,
            .min_latency_ns = min_latency_ns,
            .latency_jitter_ns = options.latency_jitter_ns,
        };
    }

    fn validateFaultRate(rate: env_module.BuggifyRate) DiskError!void {
        if (rate.denominator == 0) return error.InvalidRate;
        if (rate.numerator > rate.denominator) return error.InvalidRate;
    }

    fn validatePath(_: *const Self, path: []const u8) DiskError!void {
        if (path.len == 0) return error.InvalidPath;
    }

    fn ensureRunning(self: *const Self) DiskError!void {
        if (self.crashed) return error.DiskCrashed;
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

    fn rollFault(
        self: *Self,
        op_id: u64,
        path: []const u8,
        kind: []const u8,
        rate: env_module.BuggifyRate,
    ) DiskError!bool {
        try validateFaultRate(rate);
        if (rate.numerator == 0) return false;

        const roll = try self.world.randomIntLessThan(u32, rate.denominator);
        const fired = roll < rate.numerator;

        var rate_buffer: [32]u8 = undefined;
        const rate_literal = std.fmt.bufPrint(
            &rate_buffer,
            "{}/{}",
            .{ rate.numerator, rate.denominator },
        ) catch unreachable;

        try self.world.recordFields("disk.fault", &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = path }),
            traceField("kind", .{ .literal = kind }),
            traceField("rate", .{ .literal = rate_literal }),
            traceField("roll", .{ .uint = roll }),
            traceField("fired", .{ .literal = if (fired) "true" else "false" }),
        });

        return fired;
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

    fn appendPendingWrite(
        self: *Self,
        op_id: u64,
        path: []const u8,
        offset: u64,
        bytes: []const u8,
    ) DiskError!void {
        const owned_path = try self.world.allocator.dupe(u8, path);
        errdefer self.world.allocator.free(owned_path);

        const owned_bytes = try self.world.allocator.dupe(u8, bytes);
        errdefer self.world.allocator.free(owned_bytes);

        try self.pending_writes.append(self.world.allocator, .{
            .op_id = op_id,
            .path = owned_path,
            .offset = offset,
            .bytes = owned_bytes,
        });
    }

    fn commitPendingWrites(self: *Self, path: []const u8) DiskError!u64 {
        var committed: u64 = 0;
        var index: usize = 0;
        while (index < self.pending_writes.items.len) {
            if (!std.mem.eql(u8, self.pending_writes.items[index].path, path)) {
                index += 1;
                continue;
            }

            try self.applyFullWrite(&self.pending_writes.items[index]);
            var pending = self.pending_writes.orderedRemove(index);
            pending.deinit(self.world.allocator);
            committed += 1;
        }

        return committed;
    }

    fn clearPendingWrites(self: *Self) void {
        for (self.pending_writes.items) |*pending| pending.deinit(self.world.allocator);
        self.pending_writes.clearRetainingCapacity();
    }

    fn applyFullWrite(self: *Self, pending: *const PendingWrite) DiskError!void {
        const file = try self.getOrCreateFile(pending.path);
        try self.writeSectors(file, pending.offset, pending.bytes);
    }

    fn applyTornWrite(self: *Self, pending: *const PendingWrite) DiskError!void {
        const torn_len = pending.bytes.len / 2;
        if (torn_len == 0) return;

        const file = try self.getOrCreateFile(pending.path);
        try self.writeBytes(file, pending.offset, pending.bytes[0..torn_len]);
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

    fn rangeHasCorruption(self: *Self, path: []const u8, offset: u64, len: usize) bool {
        const file = self.findFile(path) orelse return false;
        var remaining = len;
        var sector_index = offset / self.options.sector_size;
        const sector_size: usize = @intCast(self.options.sector_size);

        while (remaining > 0) {
            if (self.findSector(file, sector_index)) |sector| {
                if (sector.corrupt) return true;
            }
            remaining -= sector_size;
            sector_index += 1;
        }

        return false;
    }

    fn overlayPendingWrites(self: *Self, path: []const u8, offset: u64, buffer: []u8) void {
        const read_start = offset;
        const read_end = read_start + buffer.len;

        for (self.pending_writes.items) |*pending| {
            if (!std.mem.eql(u8, pending.path, path)) continue;

            const write_start = pending.offset;
            const write_end = write_start + pending.bytes.len;
            const overlap_start = @max(read_start, write_start);
            const overlap_end = @min(read_end, write_end);
            if (overlap_start >= overlap_end) continue;

            const dst_start: usize = @intCast(overlap_start - read_start);
            const src_start: usize = @intCast(overlap_start - write_start);
            const overlap_len: usize = @intCast(overlap_end - overlap_start);
            @memcpy(
                buffer[dst_start..][0..overlap_len],
                pending.bytes[src_start..][0..overlap_len],
            );
        }
    }

    fn writeSectors(self: *Self, file: *File, offset: u64, bytes: []const u8) DiskError!void {
        try self.writeBytes(file, offset, bytes);
    }

    fn writeBytes(self: *Self, file: *File, offset: u64, bytes: []const u8) DiskError!void {
        var remaining = bytes;
        var cursor = offset;
        const sector_size: usize = @intCast(self.options.sector_size);

        while (remaining.len > 0) {
            const sector_index = cursor / self.options.sector_size;
            const sector_offset: usize = @intCast(cursor % self.options.sector_size);
            const writable = @min(sector_size - sector_offset, remaining.len);
            const sector = try self.getOrCreateSector(file, sector_index);
            @memcpy(sector.bytes[sector_offset..][0..writable], remaining[0..writable]);
            remaining = remaining[writable..];
            cursor += writable;
        }
    }

    fn recordCrashWrite(
        self: *Self,
        pending: *const PendingWrite,
        result: []const u8,
    ) DiskError!void {
        try self.world.recordFields("disk.crash_write", &.{
            traceField("op", .{ .uint = pending.op_id }),
            traceField("path", .{ .text = pending.path }),
            traceField("offset", .{ .uint = pending.offset }),
            traceField("len", .{ .uint = @intCast(pending.bytes.len) }),
            traceField("result", .{ .literal = result }),
        });
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

    const disk_vtable: Disk.VTable = .{
        .read = diskRead,
        .write = diskWrite,
        .sync = diskSync,
    };

    const control_vtable: DiskControl.VTable = .{
        .set_faults = controlSetFaults,
        .corrupt_sector = controlCorruptSector,
        .crash = controlCrash,
        .restart = controlRestart,
        .disk = controlDisk,
    };

    fn fromOpaque(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }

    fn diskRead(ptr: *anyopaque, options: Disk.Read) DiskError!void {
        try fromOpaque(ptr).read(options);
    }

    fn diskWrite(ptr: *anyopaque, options: Disk.Write) DiskError!void {
        try fromOpaque(ptr).write(options);
    }

    fn diskSync(ptr: *anyopaque, options: Disk.Sync) DiskError!void {
        try fromOpaque(ptr).sync(options);
    }

    fn controlSetFaults(ptr: *anyopaque, faults: DiskFaultOptions) DiskError!void {
        try fromOpaque(ptr).setFaults(faults);
    }

    fn controlCorruptSector(ptr: *anyopaque, path: []const u8, offset: u64) DiskError!void {
        try fromOpaque(ptr).corruptSector(path, offset);
    }

    fn controlCrash(ptr: *anyopaque) DiskError!void {
        try fromOpaque(ptr).crash(.{});
    }

    fn controlRestart(ptr: *anyopaque) DiskError!void {
        try fromOpaque(ptr).restart(.{});
    }

    fn controlDisk(ptr: *anyopaque) Disk {
        return fromOpaque(ptr).disk();
    }
};

test "disk: writes and reads sector-aligned logical files" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
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

test "disk: real disk writes, reads, zero-fills, syncs, and creates parent directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try RealDisk.init(tmp.dir, std.testing.io, .{ .sector_size = 4 });
    defer disk.deinit();
    const app_disk = disk.disk();

    try app_disk.write(.{
        .path = "accounts/wal.log",
        .offset = 4,
        .bytes = "abcd",
    });
    try app_disk.sync(.{ .path = "accounts/wal.log" });

    var buffer = [_]u8{0xff} ** 8;
    try app_disk.read(.{
        .path = "accounts/wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualStrings("\x00\x00\x00\x00abcd", &buffer);
}

test "disk: real disk rejects invalid paths and unaligned ranges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try RealDisk.init(tmp.dir, std.testing.io, .{ .sector_size = 4 });
    defer disk.deinit();
    const app_disk = disk.disk();

    var buffer = [_]u8{0} ** 4;
    try std.testing.expectError(error.InvalidPath, app_disk.read(.{
        .path = "../wal.log",
        .offset = 0,
        .buffer = &buffer,
    }));
    try std.testing.expectError(error.InvalidAlignment, app_disk.write(.{
        .path = "wal.log",
        .offset = 1,
        .bytes = "abcd",
    }));
    try std.testing.expectError(error.InvalidAlignment, app_disk.write(.{
        .path = "wal.log",
        .offset = 0,
        .bytes = "abc",
    }));
}

test "disk: sync consumes operation ids and escapes logical paths" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{});
    defer disk.deinit();

    try disk.sync(.{ .path = "dir/wal 1.log" });

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.sync op=0 path=dir/wal%201.log status=ok committed_writes=0 latency_ns=1") != null);
}

test "disk: rejects invalid paths, ranges, and latency options" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    try std.testing.expectError(
        error.InvalidAlignment,
        SimDisk.init(&world, .{ .sector_size = 0 }),
    );
    try std.testing.expectError(
        error.InvalidDuration,
        SimDisk.init(&world, .{ .min_latency_ns = 11 }),
    );
    try std.testing.expectError(
        error.InvalidDuration,
        SimDisk.init(&world, .{ .min_latency_ns = clock_module.default_tick_ns }),
    );

    var disk = try SimDisk.init(&world, .{ .sector_size = 4, .min_latency_ns = 10 });
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

    var disk_a = try SimDisk.init(&a, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_a.deinit();
    var disk_b = try SimDisk.init(&b, .{
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

test "disk: write errors do not mutate durable sectors" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.control().setFaults(.{ .write_error_rate = .always() });
    try std.testing.expectError(error.WriteError, disk.write(.{
        .path = "wal.log",
        .offset = 0,
        .bytes = "zzzz",
    }));

    try disk.control().setFaults(.{});
    var buffer = [_]u8{0xff} ** 4;
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 4, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=0 path=wal.log kind=write_error rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.write op=0 path=wal.log offset=0 len=4 status=io_error latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=1 path=wal.log offset=0 len=4 status=ok latency_ns=10") != null);
}

test "disk: read errors return before filling buffer" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.control().setFaults(.{ .read_error_rate = .always() });

    var buffer = [_]u8{ 'x', 'x', 'x', 'x' };
    try std.testing.expectError(error.ReadError, disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    }));

    try std.testing.expectEqualStrings("xxxx", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=1 path=wal.log kind=read_error rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=1 path=wal.log offset=0 len=4 status=io_error latency_ns=10") != null);
}

test "disk: corrupt read faults do not mutate durable sectors" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.control().setFaults(.{ .corrupt_read_rate = .always() });

    var corrupt_buffer = [_]u8{0} ** 4;
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &corrupt_buffer,
    });
    try std.testing.expect(!std.mem.eql(u8, "abcd", &corrupt_buffer));

    try disk.control().setFaults(.{});
    var clean_buffer = [_]u8{0} ** 4;
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &clean_buffer,
    });
    try std.testing.expectEqualStrings("abcd", &clean_buffer);

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=1 path=wal.log kind=corrupt_read rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=1 path=wal.log offset=0 len=4 status=corrupt latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=2 path=wal.log offset=0 len=4 status=ok latency_ns=10") != null);
}

test "disk: scripted sector corruption persists across reads" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.control().corruptSector("wal.log", 0);

    var buffer = [_]u8{0} ** 4;
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expect(!std.mem.eql(u8, "abcd", &buffer));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault path=wal.log offset=0 kind=scripted_corruption") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=1 path=wal.log offset=0 len=4 status=corrupt latency_ns=10") != null);
}

test "disk: rejects invalid fault rates" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{});
    defer disk.deinit();
    const control = disk.control();

    try std.testing.expectError(error.InvalidRate, control.setFaults(.{
        .read_error_rate = .{ .numerator = 1, .denominator = 0 },
    }));
    try std.testing.expectError(error.InvalidRate, control.setFaults(.{
        .write_error_rate = .{ .numerator = 2, .denominator = 1 },
    }));
}

test "disk: fault traces are deterministic for the same seed" {
    var a = try World.init(std.testing.allocator, .{ .seed = 99, .tick_ns = 10 });
    defer a.deinit();
    var b = try World.init(std.testing.allocator, .{ .seed = 99, .tick_ns = 10 });
    defer b.deinit();

    var disk_a = try SimDisk.init(&a, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_a.deinit();
    var disk_b = try SimDisk.init(&b, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_b.deinit();

    const faults: DiskFaultOptions = .{
        .read_error_rate = .oneIn(2),
        .write_error_rate = .oneIn(2),
        .corrupt_read_rate = .oneIn(2),
    };
    try disk_a.control().setFaults(faults);
    try disk_b.control().setFaults(faults);

    disk_a.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" }) catch |err| switch (err) {
        error.WriteError => {},
        else => return err,
    };
    disk_b.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" }) catch |err| switch (err) {
        error.WriteError => {},
        else => return err,
    };

    var buffer_a = [_]u8{0} ** 4;
    disk_a.read(.{ .path = "wal.log", .offset = 0, .buffer = &buffer_a }) catch |err| switch (err) {
        error.ReadError => {},
        else => return err,
    };

    var buffer_b = [_]u8{0} ** 4;
    disk_b.read(.{ .path = "wal.log", .offset = 0, .buffer = &buffer_b }) catch |err| switch (err) {
        error.ReadError => {},
        else => return err,
    };

    try std.testing.expectEqualStrings(a.traceBytes(), b.traceBytes());
}

test "disk: sync makes pending writes survive crash" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.sync(.{ .path = "wal.log" });
    try disk.control().setFaults(.{ .crash_lost_write_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    var buffer = [_]u8{0} ** 4;
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualStrings("abcd", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.sync op=1 path=wal.log status=ok committed_writes=1 latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash pending_writes=0 landed=0 lost=0 torn=0") != null);
}

test "disk: crash can lose unflushed pending writes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.control().setFaults(.{ .crash_lost_write_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    var buffer = [_]u8{0xff} ** 4;
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 4, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=0 path=wal.log kind=crash_lost_write rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash_write op=0 path=wal.log offset=0 len=4 result=lost") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash pending_writes=1 landed=0 lost=1 torn=0") != null);
}

test "disk: crash can tear unflushed pending writes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "wxyz" });
    try disk.sync(.{ .path = "wal.log" });
    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.control().setFaults(.{ .crash_torn_write_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    var buffer = [_]u8{0} ** 4;
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualStrings("abyz", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=2 path=wal.log kind=crash_torn_write rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash_write op=2 path=wal.log offset=0 len=4 result=torn") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash pending_writes=1 landed=0 lost=0 torn=1") != null);
}

test "disk: crashed disk rejects operations until restart" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.control().crash();

    var buffer = [_]u8{0} ** 4;
    try std.testing.expectError(error.DiskCrashed, disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    }));
    try std.testing.expectError(error.DiskCrashed, disk.write(.{
        .path = "wal.log",
        .offset = 0,
        .bytes = "abcd",
    }));
    try std.testing.expectError(error.DiskCrashed, disk.sync(.{ .path = "wal.log" }));

    try disk.control().restart();
    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
}

test "disk: crash traces are deterministic for the same seed" {
    var a = try World.init(std.testing.allocator, .{ .seed = 99, .tick_ns = 10 });
    defer a.deinit();
    var b = try World.init(std.testing.allocator, .{ .seed = 99, .tick_ns = 10 });
    defer b.deinit();

    var disk_a = try SimDisk.init(&a, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_a.deinit();
    var disk_b = try SimDisk.init(&b, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_b.deinit();

    const faults: DiskFaultOptions = .{
        .crash_lost_write_rate = .oneIn(2),
        .crash_torn_write_rate = .oneIn(2),
    };
    try disk_a.control().setFaults(faults);
    try disk_b.control().setFaults(faults);

    try disk_a.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk_b.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk_a.control().crash();
    try disk_b.control().crash();

    try std.testing.expectEqualStrings(a.traceBytes(), b.traceBytes());
}
