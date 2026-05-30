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
    FileNotFound,
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
    crash_reordered_write_rate: env_module.BuggifyRate = .never(),
    crash_lost_metadata_rate: env_module.BuggifyRate = .never(),
};

pub const Disk = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Read = DiskRead;
    pub const Write = DiskWrite;
    pub const Sync = DiskSync;
    pub const SyncDir = DiskSyncDir;
    pub const Stat = DiskStat;
    pub const StatResult = DiskStatResult;
    pub const ReadSome = DiskReadSome;
    pub const SetLength = DiskSetLength;
    pub const Delete = DiskDelete;
    pub const Rename = DiskRename;

    pub const VTable = struct {
        read: *const fn (*anyopaque, Read) DiskError!void,
        write: *const fn (*anyopaque, Write) DiskError!void,
        sync: *const fn (*anyopaque, Sync) DiskError!void,
        sync_dir: *const fn (*anyopaque, SyncDir) DiskError!void,
        stat: *const fn (*anyopaque, Stat) DiskError!StatResult,
        read_some: *const fn (*anyopaque, ReadSome) DiskError!usize,
        set_length: *const fn (*anyopaque, SetLength) DiskError!void,
        delete: *const fn (*anyopaque, Delete) DiskError!void,
        rename: *const fn (*anyopaque, Rename) DiskError!void,
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

    /// Persist directory-entry metadata for files under `path`.
    ///
    /// Use "." for the root logical directory. File `sync` persists file
    /// contents; `syncDir` persists creates, deletes, and renames.
    pub fn syncDir(self: Disk, options: SyncDir) DiskError!void {
        try self.vtable.sync_dir(self.ptr, options);
    }

    pub fn stat(self: Disk, options: Stat) DiskError!StatResult {
        return try self.vtable.stat(self.ptr, options);
    }

    /// Read up to `buffer.len` bytes, returning the number of bytes copied.
    ///
    /// Unlike `read`, this is EOF-aware and byte-oriented. It does not
    /// zero-fill past the current logical file size.
    pub fn readSome(self: Disk, options: ReadSome) DiskError!usize {
        return try self.vtable.read_some(self.ptr, options);
    }

    pub fn setLength(self: Disk, options: SetLength) DiskError!void {
        try self.vtable.set_length(self.ptr, options);
    }

    pub fn delete(self: Disk, options: Delete) DiskError!void {
        try self.vtable.delete(self.ptr, options);
    }

    pub fn rename(self: Disk, options: Rename) DiskError!void {
        try self.vtable.rename(self.ptr, options);
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
    .sync_dir = unavailableSyncDir,
    .stat = unavailableStat,
    .read_some = unavailableReadSome,
    .set_length = unavailableSetLength,
    .delete = unavailableDelete,
    .rename = unavailableRename,
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

fn unavailableSyncDir(_: *anyopaque, _: Disk.SyncDir) DiskError!void {
    return error.DiskUnavailable;
}

fn unavailableStat(_: *anyopaque, _: Disk.Stat) DiskError!Disk.StatResult {
    return error.DiskUnavailable;
}

fn unavailableReadSome(_: *anyopaque, _: Disk.ReadSome) DiskError!usize {
    return error.DiskUnavailable;
}

fn unavailableSetLength(_: *anyopaque, _: Disk.SetLength) DiskError!void {
    return error.DiskUnavailable;
}

fn unavailableDelete(_: *anyopaque, _: Disk.Delete) DiskError!void {
    return error.DiskUnavailable;
}

fn unavailableRename(_: *anyopaque, _: Disk.Rename) DiskError!void {
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

pub const DiskSyncDir = struct {
    path: []const u8,
};

pub const DiskStat = struct {
    path: []const u8,
};

pub const DiskStatResult = struct {
    size: u64,
};

pub const DiskReadSome = struct {
    path: []const u8,
    offset: u64,
    buffer: []u8,
};

pub const DiskSetLength = struct {
    path: []const u8,
    len: u64,
};

pub const DiskDelete = struct {
    path: []const u8,
};

pub const DiskRename = struct {
    old_path: []const u8,
    new_path: []const u8,
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

    fn syncDir(self: *Self, options: Disk.SyncDir) DiskError!void {
        try self.validatePath(options.path);
        // `std.Io` does not expose directory fsync on all backends yet. Keep
        // the production adapter surface-compatible; real host durability is
        // still delegated to the platform and filesystem.
    }

    fn stat(self: *Self, options: Disk.Stat) DiskError!Disk.StatResult {
        try self.validatePath(options.path);
        const file_stat = self.root.statFile(self.io, options.path, .{}) catch |err| {
            return mapStatError(err);
        };
        return .{ .size = file_stat.size };
    }

    fn readSome(self: *Self, options: Disk.ReadSome) DiskError!usize {
        try self.validatePath(options.path);
        try validateByteRange(options.offset, options.buffer.len);

        var file = self.root.openFile(self.io, options.path, .{
            .mode = .read_only,
            .allow_directory = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return mapOpenReadError(err),
        };
        defer file.close(self.io);

        return file.readPositionalAll(self.io, options.buffer, options.offset) catch |err| {
            return mapReadError(err);
        };
    }

    fn setLength(self: *Self, options: Disk.SetLength) DiskError!void {
        try self.validatePath(options.path);

        var file = self.root.openFile(self.io, options.path, .{
            .mode = .read_write,
            .allow_directory = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return mapOpenWriteError(err),
        };
        defer file.close(self.io);

        file.setLength(self.io, options.len) catch |err| {
            return mapSetLengthError(err);
        };
    }

    fn delete(self: *Self, options: Disk.Delete) DiskError!void {
        try self.validatePath(options.path);
        self.root.deleteFile(self.io, options.path) catch |err| {
            return mapDeleteError(err);
        };
    }

    fn rename(self: *Self, options: Disk.Rename) DiskError!void {
        try self.validatePath(options.old_path);
        try self.validatePath(options.new_path);
        try self.ensureParentDirs(options.new_path);
        std.Io.Dir.rename(self.root, options.old_path, self.root, options.new_path, self.io) catch |err| {
            return mapRenameError(err);
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
        .sync_dir = diskSyncDir,
        .stat = diskStat,
        .read_some = diskReadSome,
        .set_length = diskSetLength,
        .delete = diskDelete,
        .rename = diskRename,
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

    fn diskSyncDir(ptr: *anyopaque, options: Disk.SyncDir) DiskError!void {
        try fromOpaque(ptr).syncDir(options);
    }

    fn diskStat(ptr: *anyopaque, options: Disk.Stat) DiskError!Disk.StatResult {
        return try fromOpaque(ptr).stat(options);
    }

    fn diskReadSome(ptr: *anyopaque, options: Disk.ReadSome) DiskError!usize {
        return try fromOpaque(ptr).readSome(options);
    }

    fn diskSetLength(ptr: *anyopaque, options: Disk.SetLength) DiskError!void {
        try fromOpaque(ptr).setLength(options);
    }

    fn diskDelete(ptr: *anyopaque, options: Disk.Delete) DiskError!void {
        try fromOpaque(ptr).delete(options);
    }

    fn diskRename(ptr: *anyopaque, options: Disk.Rename) DiskError!void {
        try fromOpaque(ptr).rename(options);
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

fn mapStatError(err: std.Io.Dir.StatFileError) DiskError {
    return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.IsDir,
        error.NotDir,
        error.SymLinkLoop,
        => error.InvalidPath,
        else => error.ReadError,
    };
}

fn mapSetLengthError(err: std.Io.File.SetLengthError) DiskError {
    return switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        error.NonResizable,
        => error.InvalidPath,
        else => error.WriteError,
    };
}

fn mapDeleteError(err: std.Io.Dir.DeleteFileError) DiskError {
    return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.IsDir,
        error.NotDir,
        error.SymLinkLoop,
        => error.InvalidPath,
        else => error.WriteError,
    };
}

fn mapRenameError(err: std.Io.Dir.RenameError) DiskError {
    return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.IsDir,
        error.NotDir,
        error.SymLinkLoop,
        error.CrossDevice,
        => error.InvalidPath,
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

fn validateByteRange(offset: u64, len: usize) DiskError!void {
    const len_u64: u64 = @intCast(len);
    if (std.math.maxInt(u64) - offset < len_u64) return error.InvalidRange;
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
    pub const SyncDir = DiskSyncDir;
    pub const Crash = DiskCrash;
    pub const Restart = DiskRestart;

    const FileId = u64;

    const File = struct {
        id: FileId,
        path: []u8,
        len: u64 = 0,
        metadata_durable: bool = true,
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

    const PendingMetadata = struct {
        op_id: u64,
        dir: []u8,
        other_dir: ?[]u8 = null,
        dir_synced: bool = false,
        other_dir_synced: bool = false,
        kind: Kind,

        const Kind = union(enum) {
            create: FileId,
            delete: ?File,
            rename: RenameUndo,
        };

        const RenameUndo = struct {
            file_id: FileId,
            old_path: ?[]u8,
            replaced: ?File = null,

            fn deinit(self: *RenameUndo, allocator: std.mem.Allocator) void {
                if (self.old_path) |path| allocator.free(path);
                if (self.replaced) |*file| file.deinit(allocator);
                self.* = undefined;
            }
        };

        fn deinit(self: *PendingMetadata, allocator: std.mem.Allocator) void {
            allocator.free(self.dir);
            if (self.other_dir) |dir| allocator.free(dir);
            switch (self.kind) {
                .create => {},
                .delete => |*file| if (file.*) |*owned| owned.deinit(allocator),
                .rename => |*undo| undo.deinit(allocator),
            }
            self.* = undefined;
        }
    };

    world: *World,
    options: ResolvedOptions,
    faults: DiskFaultOptions = .{},
    files: std.ArrayList(File) = .empty,
    pending_writes: std.ArrayList(PendingWrite) = .empty,
    pending_metadata: std.ArrayList(PendingMetadata) = .empty,
    next_op_id: u64 = 0,
    next_file_id: FileId = 1,
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

    pub fn sectorSize(self: *const Self) u64 {
        return self.options.sector_size;
    }

    pub fn deinit(self: *Self) void {
        for (self.files.items) |*file| file.deinit(self.world.allocator);
        self.files.deinit(self.world.allocator);
        for (self.pending_writes.items) |*pending| pending.deinit(self.world.allocator);
        self.pending_writes.deinit(self.world.allocator);
        for (self.pending_metadata.items) |*pending| pending.deinit(self.world.allocator);
        self.pending_metadata.deinit(self.world.allocator);
        self.* = undefined;
    }

    fn setFaults(self: *Self, faults: DiskFaultOptions) DiskError!void {
        try validateFaultRate(faults.read_error_rate);
        try validateFaultRate(faults.write_error_rate);
        try validateFaultRate(faults.corrupt_read_rate);
        try validateFaultRate(faults.crash_lost_write_rate);
        try validateFaultRate(faults.crash_torn_write_rate);
        try validateFaultRate(faults.crash_reordered_write_rate);
        try validateFaultRate(faults.crash_lost_metadata_rate);
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

    fn syncDir(self: *Self, options: SyncDir) DiskError!void {
        try self.validatePath(options.path);
        try self.ensureRunning();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const committed = self.commitPendingMetadata(options.path);

        try self.world.recordFields("disk.sync_dir", &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = options.path }),
            traceField("status", .{ .literal = "ok" }),
            traceField("committed_metadata", .{ .uint = committed }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
    }

    fn stat(self: *Self, options: Disk.Stat) DiskError!Disk.StatResult {
        try self.validatePath(options.path);
        try self.ensureRunning();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const size = self.visibleLength(options.path) orelse {
            try self.recordPathOp("disk.stat", op_id, options.path, "not_found", latency_ns);
            return error.FileNotFound;
        };

        try self.world.recordFields("disk.stat", &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = options.path }),
            traceField("status", .{ .literal = "ok" }),
            traceField("size", .{ .uint = size }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
        return .{ .size = size };
    }

    fn readSome(self: *Self, options: Disk.ReadSome) DiskError!usize {
        try self.validatePath(options.path);
        try validateByteRange(options.offset, options.buffer.len);
        try self.ensureRunning();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const size = self.visibleLength(options.path) orelse {
            try self.recordRangeOp(
                "disk.read_some",
                op_id,
                options.path,
                options.offset,
                options.buffer.len,
                "not_found",
                latency_ns,
            );
            return error.FileNotFound;
        };

        if (try self.rollFault(op_id, options.path, "read_error", self.faults.read_error_rate)) {
            try self.recordRangeOp(
                "disk.read_some",
                op_id,
                options.path,
                options.offset,
                options.buffer.len,
                "io_error",
                latency_ns,
            );
            return error.ReadError;
        }

        const read_len: usize = if (options.offset >= size)
            0
        else
            @intCast(@min(@as(u64, @intCast(options.buffer.len)), size - options.offset));

        if (read_len > 0) {
            @memset(options.buffer[0..read_len], 0);
            if (self.findFile(options.path)) |file| {
                try self.readBytes(file, options.offset, options.buffer[0..read_len]);
            }
            self.overlayPendingWrites(options.path, options.offset, options.buffer[0..read_len]);
        }

        const corrupt = read_len > 0 and
            (self.rangeHasCorruptionBytes(options.path, options.offset, read_len) or
                try self.rollFault(op_id, options.path, "corrupt_read", self.faults.corrupt_read_rate));
        const status = if (corrupt) "corrupt" else "ok";
        if (corrupt) {
            options.buffer[0] ^= 0xff;
        }

        try self.world.recordFields("disk.read_some", &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = options.path }),
            traceField("offset", .{ .uint = options.offset }),
            traceField("requested_len", .{ .uint = @intCast(options.buffer.len) }),
            traceField("read_len", .{ .uint = @intCast(read_len) }),
            traceField("status", .{ .literal = status }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
        return read_len;
    }

    fn setLength(self: *Self, options: Disk.SetLength) DiskError!void {
        try self.validatePath(options.path);
        try self.ensureRunning();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const committed = try self.commitPendingWrites(options.path);
        const file = self.findFile(options.path) orelse {
            try self.recordMetadataOp("disk.set_length", op_id, options.path, options.len, committed, "not_found", latency_ns);
            return error.FileNotFound;
        };

        try self.truncateFile(file, options.len);
        file.len = options.len;
        try self.recordMetadataOp("disk.set_length", op_id, options.path, options.len, committed, "ok", latency_ns);
    }

    fn delete(self: *Self, options: Disk.Delete) DiskError!void {
        try self.validatePath(options.path);
        try self.ensureRunning();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const committed = try self.commitPendingWrites(options.path);
        const index = self.findFileIndex(options.path) orelse {
            try self.recordLifecycleOp("disk.delete", op_id, options.path, null, committed, "not_found", latency_ns);
            return error.FileNotFound;
        };

        const dir = try self.ownedParentDir(options.path);
        var dir_owned = true;
        errdefer if (dir_owned) self.world.allocator.free(dir);
        try self.pending_metadata.ensureUnusedCapacity(self.world.allocator, 1);

        const deleted = self.files.orderedRemove(index);
        self.pending_metadata.appendAssumeCapacity(.{
            .op_id = op_id,
            .dir = dir,
            .kind = .{ .delete = deleted },
        });
        dir_owned = false;
        self.clearPendingWritesFor(options.path);
        try self.recordLifecycleOp("disk.delete", op_id, options.path, null, committed, "ok", latency_ns);
    }

    fn rename(self: *Self, options: Disk.Rename) DiskError!void {
        try self.validatePath(options.old_path);
        try self.validatePath(options.new_path);
        try self.ensureRunning();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const committed = try self.commitPendingWrites(options.old_path);
        const old_index = self.findFileIndex(options.old_path) orelse {
            try self.recordLifecycleOp("disk.rename", op_id, options.old_path, options.new_path, committed, "not_found", latency_ns);
            return error.FileNotFound;
        };
        if (std.mem.eql(u8, options.old_path, options.new_path)) {
            try self.recordLifecycleOp("disk.rename", op_id, options.old_path, options.new_path, committed, "ok", latency_ns);
            return;
        }

        const owned_old_path = try self.world.allocator.dupe(u8, options.old_path);
        var old_path_owned = true;
        errdefer if (old_path_owned) self.world.allocator.free(owned_old_path);
        const owned_new_path = try self.world.allocator.dupe(u8, options.new_path);
        var new_path_owned = true;
        errdefer if (new_path_owned) self.world.allocator.free(owned_new_path);
        const old_dir = try self.ownedParentDir(options.old_path);
        var old_dir_owned = true;
        errdefer if (old_dir_owned) self.world.allocator.free(old_dir);
        const new_dir = try self.ownedParentDir(options.new_path);
        var new_dir_owned = true;
        errdefer if (new_dir_owned) self.world.allocator.free(new_dir);
        try self.pending_metadata.ensureUnusedCapacity(self.world.allocator, 1);

        var file_id: FileId = self.files.items[old_index].id;
        var replaced: ?File = null;
        if (self.findFileIndex(options.new_path)) |new_index| {
            if (new_index != old_index) {
                var old_index_adjusted = old_index;
                replaced = self.files.orderedRemove(new_index);
                if (new_index < old_index_adjusted) old_index_adjusted -= 1;
                self.clearPendingWritesFor(options.new_path);
                file_id = self.files.items[old_index_adjusted].id;
                self.world.allocator.free(self.files.items[old_index_adjusted].path);
                self.files.items[old_index_adjusted].path = owned_new_path;
                new_path_owned = false;
            }
        } else {
            self.world.allocator.free(self.files.items[old_index].path);
            self.files.items[old_index].path = owned_new_path;
            new_path_owned = false;
        }

        self.pending_metadata.appendAssumeCapacity(.{
            .op_id = op_id,
            .dir = old_dir,
            .other_dir = if (std.mem.eql(u8, old_dir, new_dir)) null else new_dir,
            .kind = .{ .rename = .{
                .file_id = file_id,
                .old_path = owned_old_path,
                .replaced = replaced,
            } },
        });
        old_path_owned = false;
        old_dir_owned = false;
        new_dir_owned = std.mem.eql(u8, old_dir, new_dir);

        try self.recordLifecycleOp("disk.rename", op_id, options.old_path, options.new_path, committed, "ok", latency_ns);
    }

    fn crash(self: *Self, _: Crash) DiskError!void {
        try self.ensureRunning();

        const pending_count = self.pending_writes.items.len;
        var landed: u64 = 0;
        var lost: u64 = 0;
        var torn: u64 = 0;
        var reordered: u64 = 0;
        const CrashLanding = struct {
            index: usize,
            result: []const u8,
        };
        var landing = std.ArrayList(CrashLanding).empty;
        defer landing.deinit(self.world.allocator);
        var apply_reordered = false;

        for (self.pending_writes.items, 0..) |*pending, index| {
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

            if (try self.rollFault(
                pending.op_id,
                pending.path,
                "crash_reordered_write",
                self.faults.crash_reordered_write_rate,
            )) {
                try landing.append(self.world.allocator, .{ .index = index, .result = "reordered" });
                reordered += 1;
                apply_reordered = true;
                continue;
            }

            try landing.append(self.world.allocator, .{ .index = index, .result = "landed" });
            landed += 1;
        }

        if (apply_reordered) {
            var index = landing.items.len;
            while (index > 0) {
                index -= 1;
                const item = landing.items[index];
                const pending = &self.pending_writes.items[item.index];
                try self.applyFullWrite(pending);
                try self.recordCrashWrite(pending, item.result);
            }
        } else {
            for (landing.items) |item| {
                const pending = &self.pending_writes.items[item.index];
                try self.applyFullWrite(pending);
                try self.recordCrashWrite(pending, item.result);
            }
        }
        self.clearPendingWrites();

        const pending_metadata_count = self.pending_metadata.items.len;
        var metadata_kept: u64 = 0;
        var metadata_lost: u64 = 0;
        var index = self.pending_metadata.items.len;
        while (index > 0) {
            index -= 1;
            const pending = &self.pending_metadata.items[index];
            if (try self.rollFault(
                pending.op_id,
                pending.dir,
                "crash_lost_metadata",
                self.faults.crash_lost_metadata_rate,
            )) {
                try self.rollbackPendingMetadata(pending);
                metadata_lost += 1;
                try self.recordCrashMetadata(pending, "lost");
            } else {
                self.markMetadataDurable(pending);
                metadata_kept += 1;
                try self.recordCrashMetadata(pending, "kept");
            }
        }
        self.clearPendingMetadata();
        self.crashed = true;

        try self.world.recordFields("disk.crash", &.{
            traceField("pending_writes", .{ .uint = @intCast(pending_count) }),
            traceField("landed", .{ .uint = landed }),
            traceField("lost", .{ .uint = lost }),
            traceField("torn", .{ .uint = torn }),
            traceField("reordered", .{ .uint = reordered }),
            traceField("pending_metadata", .{ .uint = @intCast(pending_metadata_count) }),
            traceField("metadata_kept", .{ .uint = metadata_kept }),
            traceField("metadata_lost", .{ .uint = metadata_lost }),
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

    fn ownedParentDir(self: *Self, path: []const u8) DiskError![]u8 {
        const parent = std.fs.path.dirname(path) orelse ".";
        return try self.world.allocator.dupe(u8, parent);
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

    fn findFileIndex(self: *Self, path: []const u8) ?usize {
        for (self.files.items, 0..) |*file, index| {
            if (std.mem.eql(u8, file.path, path)) return index;
        }
        return null;
    }

    fn findFileById(self: *Self, id: FileId) ?*File {
        for (self.files.items) |*file| {
            if (file.id == id) return file;
        }
        return null;
    }

    fn findFileIndexById(self: *Self, id: FileId) ?usize {
        for (self.files.items, 0..) |*file, index| {
            if (file.id == id) return index;
        }
        return null;
    }

    fn getOrCreateFile(self: *Self, path: []const u8) DiskError!*File {
        if (self.findFile(path)) |file| return file;

        const owned_path = try self.world.allocator.dupe(u8, path);
        errdefer self.world.allocator.free(owned_path);

        const id = self.next_file_id;
        self.next_file_id += 1;
        try self.files.append(self.world.allocator, .{
            .id = id,
            .path = owned_path,
            .metadata_durable = false,
        });
        return &self.files.items[self.files.items.len - 1];
    }

    fn ensurePendingCreate(self: *Self, op_id: u64, file: *const File) DiskError!void {
        if (file.metadata_durable) return;
        for (self.pending_metadata.items) |pending| switch (pending.kind) {
            .create => |id| if (id == file.id) return,
            .delete, .rename => {},
        };

        const dir = try self.ownedParentDir(file.path);
        errdefer self.world.allocator.free(dir);
        try self.pending_metadata.append(self.world.allocator, .{
            .op_id = op_id,
            .dir = dir,
            .kind = .{ .create = file.id },
        });
    }

    fn appendPendingDelete(self: *Self, op_id: u64, path: []const u8, deleted: File) DiskError!void {
        const dir = try self.ownedParentDir(path);
        errdefer self.world.allocator.free(dir);
        try self.pending_metadata.append(self.world.allocator, .{
            .op_id = op_id,
            .dir = dir,
            .kind = .{ .delete = deleted },
        });
    }

    fn appendPendingRename(
        self: *Self,
        op_id: u64,
        new_path: []const u8,
        file_id: FileId,
        owned_old_path: []u8,
        replaced: ?File,
    ) DiskError!void {
        const dir = try self.ownedParentDir(new_path);
        errdefer self.world.allocator.free(dir);
        try self.pending_metadata.append(self.world.allocator, .{
            .op_id = op_id,
            .dir = dir,
            .kind = .{ .rename = .{
                .file_id = file_id,
                .old_path = owned_old_path,
                .replaced = replaced,
            } },
        });
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

    fn clearPendingWritesFor(self: *Self, path: []const u8) void {
        var index: usize = 0;
        while (index < self.pending_writes.items.len) {
            if (!std.mem.eql(u8, self.pending_writes.items[index].path, path)) {
                index += 1;
                continue;
            }
            var pending = self.pending_writes.orderedRemove(index);
            pending.deinit(self.world.allocator);
        }
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

    fn commitPendingMetadata(self: *Self, dir: []const u8) u64 {
        var committed: u64 = 0;
        var index: usize = 0;
        while (index < self.pending_metadata.items.len) {
            const pending = &self.pending_metadata.items[index];
            if (!markPendingMetadataDirSynced(pending, dir)) {
                index += 1;
                continue;
            }

            if (!pendingMetadataSynced(pending)) {
                index += 1;
                continue;
            }

            self.markMetadataDurable(pending);
            var removed = self.pending_metadata.orderedRemove(index);
            removed.deinit(self.world.allocator);
            committed += 1;
        }
        return committed;
    }

    fn markPendingMetadataDirSynced(pending: *PendingMetadata, dir: []const u8) bool {
        var matched = false;
        if (std.mem.eql(u8, pending.dir, dir)) {
            pending.dir_synced = true;
            matched = true;
        }
        if (pending.other_dir) |other_dir| {
            if (std.mem.eql(u8, other_dir, dir)) {
                pending.other_dir_synced = true;
                matched = true;
            }
        }
        return matched;
    }

    fn pendingMetadataSynced(pending: *const PendingMetadata) bool {
        return pending.dir_synced and (pending.other_dir == null or pending.other_dir_synced);
    }

    fn clearPendingMetadata(self: *Self) void {
        for (self.pending_metadata.items) |*pending| pending.deinit(self.world.allocator);
        self.pending_metadata.clearRetainingCapacity();
    }

    fn markMetadataDurable(self: *Self, pending: *const PendingMetadata) void {
        switch (pending.kind) {
            .create => |id| {
                if (self.findFileById(id)) |file| file.metadata_durable = true;
            },
            .delete => {},
            .rename => |rename_undo| {
                if (self.findFileById(rename_undo.file_id)) |file| file.metadata_durable = true;
            },
        }
    }

    fn rollbackPendingMetadata(self: *Self, pending: *PendingMetadata) DiskError!void {
        switch (pending.kind) {
            .create => |id| {
                if (self.findFileIndexById(id)) |index| {
                    var file = self.files.orderedRemove(index);
                    file.deinit(self.world.allocator);
                }
            },
            .delete => |*deleted| {
                if (deleted.*) |file| {
                    try self.files.append(self.world.allocator, file);
                    deleted.* = null;
                }
            },
            .rename => |*rename_undo| {
                if (self.findFileById(rename_undo.file_id)) |file| {
                    if (rename_undo.old_path) |old_path| {
                        self.world.allocator.free(file.path);
                        file.path = old_path;
                        rename_undo.old_path = null;
                    }
                }
                if (rename_undo.replaced) |file| {
                    try self.files.append(self.world.allocator, file);
                    rename_undo.replaced = null;
                }
            },
        }
    }

    fn applyFullWrite(self: *Self, pending: *const PendingWrite) DiskError!void {
        const file = try self.getOrCreateFile(pending.path);
        try self.ensurePendingCreate(pending.op_id, file);
        try self.writeSectors(file, pending.offset, pending.bytes);
        file.len = @max(file.len, try endOffset(pending.offset, pending.bytes.len));
    }

    fn applyTornWrite(self: *Self, pending: *const PendingWrite) DiskError!void {
        const torn_len = pending.bytes.len / 2;
        if (torn_len == 0) return;

        const file = try self.getOrCreateFile(pending.path);
        try self.ensurePendingCreate(pending.op_id, file);
        try self.writeBytes(file, pending.offset, pending.bytes[0..torn_len]);
        file.len = @max(file.len, try endOffset(pending.offset, torn_len));
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

    fn readBytes(self: *Self, file: *File, offset: u64, buffer: []u8) DiskError!void {
        var remaining = buffer;
        var cursor = offset;
        const sector_size: usize = @intCast(self.options.sector_size);

        while (remaining.len > 0) {
            const sector_index = cursor / self.options.sector_size;
            const sector_offset: usize = @intCast(cursor % self.options.sector_size);
            const readable = @min(sector_size - sector_offset, remaining.len);
            if (self.findSector(file, sector_index)) |sector| {
                @memcpy(remaining[0..readable], sector.bytes[sector_offset..][0..readable]);
            }
            remaining = remaining[readable..];
            cursor += readable;
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

    fn rangeHasCorruptionBytes(self: *Self, path: []const u8, offset: u64, len: usize) bool {
        const file = self.findFile(path) orelse return false;
        var remaining = len;
        var cursor = offset;
        const sector_size: usize = @intCast(self.options.sector_size);

        while (remaining > 0) {
            const sector_index = cursor / self.options.sector_size;
            const sector_offset: usize = @intCast(cursor % self.options.sector_size);
            const readable = @min(sector_size - sector_offset, remaining);
            if (self.findSector(file, sector_index)) |sector| {
                if (sector.corrupt) return true;
            }
            remaining -= readable;
            cursor += readable;
        }

        return false;
    }

    fn visibleLength(self: *Self, path: []const u8) ?u64 {
        var found = false;
        var len: u64 = 0;
        if (self.findFile(path)) |file| {
            found = true;
            len = file.len;
        }
        for (self.pending_writes.items) |*pending| {
            if (!std.mem.eql(u8, pending.path, path)) continue;
            found = true;
            len = @max(len, endOffset(pending.offset, pending.bytes.len) catch std.math.maxInt(u64));
        }
        return if (found) len else null;
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

    fn truncateFile(self: *Self, file: *File, len: u64) DiskError!void {
        const sector_size = self.options.sector_size;
        const keep_sector_count = if (len == 0) 0 else (len - 1) / sector_size + 1;

        var index: usize = 0;
        while (index < file.sectors.items.len) {
            if (file.sectors.items[index].index < keep_sector_count) {
                index += 1;
                continue;
            }
            var sector = file.sectors.orderedRemove(index);
            sector.deinit(self.world.allocator);
        }

        if (len > 0 and len % sector_size != 0) {
            const last_sector_index = len / sector_size;
            const keep_bytes: usize = @intCast(len % sector_size);
            if (self.findSector(file, last_sector_index)) |sector| {
                @memset(sector.bytes[keep_bytes..], 0);
            }
        }
    }

    fn endOffset(offset: u64, len: usize) DiskError!u64 {
        const len_u64: u64 = @intCast(len);
        if (std.math.maxInt(u64) - offset < len_u64) return error.InvalidRange;
        return offset + len_u64;
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

    fn recordCrashMetadata(
        self: *Self,
        pending: *const PendingMetadata,
        result: []const u8,
    ) DiskError!void {
        try self.world.recordFields("disk.crash_metadata", &.{
            traceField("op", .{ .uint = pending.op_id }),
            traceField("dir", .{ .text = pending.dir }),
            traceField("kind", .{ .literal = @tagName(pending.kind) }),
            traceField("result", .{ .literal = result }),
        });
    }

    fn recordPathOp(
        self: *Self,
        name: []const u8,
        op_id: u64,
        path: []const u8,
        status: []const u8,
        latency_ns: clock_module.Duration,
    ) DiskError!void {
        try self.world.recordFields(name, &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = path }),
            traceField("status", .{ .literal = status }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
    }

    fn recordMetadataOp(
        self: *Self,
        name: []const u8,
        op_id: u64,
        path: []const u8,
        len: u64,
        committed: u64,
        status: []const u8,
        latency_ns: clock_module.Duration,
    ) DiskError!void {
        try self.world.recordFields(name, &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = path }),
            traceField("len", .{ .uint = len }),
            traceField("status", .{ .literal = status }),
            traceField("committed_writes", .{ .uint = committed }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
    }

    fn recordLifecycleOp(
        self: *Self,
        name: []const u8,
        op_id: u64,
        path: []const u8,
        new_path: ?[]const u8,
        committed: u64,
        status: []const u8,
        latency_ns: clock_module.Duration,
    ) DiskError!void {
        if (new_path) |renamed_to| {
            try self.world.recordFields(name, &.{
                traceField("op", .{ .uint = op_id }),
                traceField("path", .{ .text = path }),
                traceField("new_path", .{ .text = renamed_to }),
                traceField("status", .{ .literal = status }),
                traceField("committed_writes", .{ .uint = committed }),
                traceField("latency_ns", .{ .uint = latency_ns }),
            });
        } else {
            try self.world.recordFields(name, &.{
                traceField("op", .{ .uint = op_id }),
                traceField("path", .{ .text = path }),
                traceField("status", .{ .literal = status }),
                traceField("committed_writes", .{ .uint = committed }),
                traceField("latency_ns", .{ .uint = latency_ns }),
            });
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

    const disk_vtable: Disk.VTable = .{
        .read = diskRead,
        .write = diskWrite,
        .sync = diskSync,
        .sync_dir = diskSyncDir,
        .stat = diskStat,
        .read_some = diskReadSome,
        .set_length = diskSetLength,
        .delete = diskDelete,
        .rename = diskRename,
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

    fn diskSyncDir(ptr: *anyopaque, options: Disk.SyncDir) DiskError!void {
        try fromOpaque(ptr).syncDir(options);
    }

    fn diskStat(ptr: *anyopaque, options: Disk.Stat) DiskError!Disk.StatResult {
        return try fromOpaque(ptr).stat(options);
    }

    fn diskReadSome(ptr: *anyopaque, options: Disk.ReadSome) DiskError!usize {
        return try fromOpaque(ptr).readSome(options);
    }

    fn diskSetLength(ptr: *anyopaque, options: Disk.SetLength) DiskError!void {
        try fromOpaque(ptr).setLength(options);
    }

    fn diskDelete(ptr: *anyopaque, options: Disk.Delete) DiskError!void {
        try fromOpaque(ptr).delete(options);
    }

    fn diskRename(ptr: *anyopaque, options: Disk.Rename) DiskError!void {
        try fromOpaque(ptr).rename(options);
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

    var buffer: [8]u8 = @splat(0);
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

    var buffer: [8]u8 = @splat(0xff);
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

    var buffer: [4]u8 = @splat(0);
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

test "disk: lifecycle operations are deterministic and trace-visible" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();
    const app_disk = disk.disk();

    try app_disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try std.testing.expectEqual(@as(u64, 4), (try app_disk.stat(.{ .path = "wal.log" })).size);

    var small: [2]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(usize, 2), try app_disk.readSome(.{
        .path = "wal.log",
        .offset = 2,
        .buffer = &small,
    }));
    try std.testing.expectEqualStrings("cd", &small);

    var eof_buffer: [4]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(usize, 0), try app_disk.readSome(.{
        .path = "wal.log",
        .offset = 4,
        .buffer = &eof_buffer,
    }));
    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0xff)), &eof_buffer);

    try app_disk.setLength(.{ .path = "wal.log", .len = 2 });
    try std.testing.expectEqual(@as(u64, 2), (try app_disk.stat(.{ .path = "wal.log" })).size);

    try app_disk.rename(.{ .old_path = "wal.log", .new_path = "archive/wal.log" });
    try std.testing.expectError(error.FileNotFound, app_disk.stat(.{ .path = "wal.log" }));
    try std.testing.expectEqual(@as(u64, 2), (try app_disk.stat(.{ .path = "archive/wal.log" })).size);

    try app_disk.delete(.{ .path = "archive/wal.log" });
    try std.testing.expectError(error.FileNotFound, app_disk.stat(.{ .path = "archive/wal.log" }));

    const trace = world.traceBytes();
    try std.testing.expect(std.mem.indexOf(u8, trace, "disk.stat op=1 path=wal.log status=ok size=4 latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "disk.read_some op=2 path=wal.log offset=2 requested_len=2 read_len=2 status=ok latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "disk.set_length op=4 path=wal.log len=2 status=ok committed_writes=1 latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "disk.rename op=6 path=wal.log new_path=archive/wal.log status=ok committed_writes=0 latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "disk.delete op=9 path=archive/wal.log status=ok committed_writes=0 latency_ns=10") != null);
}

test "disk: real disk supports lifecycle operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try RealDisk.init(tmp.dir, std.testing.io, .{ .sector_size = 4 });
    defer disk.deinit();
    const app_disk = disk.disk();

    try app_disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try std.testing.expectEqual(@as(u64, 4), (try app_disk.stat(.{ .path = "wal.log" })).size);

    var buffer: [3]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(usize, 2), try app_disk.readSome(.{
        .path = "wal.log",
        .offset = 2,
        .buffer = &buffer,
    }));
    try std.testing.expectEqualSlices(u8, "cd", buffer[0..2]);
    try std.testing.expectEqual(@as(u8, 0xff), buffer[2]);

    try app_disk.setLength(.{ .path = "wal.log", .len = 1 });
    try app_disk.rename(.{ .old_path = "wal.log", .new_path = "compact/wal.log" });
    try std.testing.expectEqual(@as(u64, 1), (try app_disk.stat(.{ .path = "compact/wal.log" })).size);
    try app_disk.delete(.{ .path = "compact/wal.log" });
    try std.testing.expectError(error.FileNotFound, app_disk.stat(.{ .path = "compact/wal.log" }));
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

    var buffer: [4]u8 = @splat(0);
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
    var buffer: [4]u8 = @splat(0xff);
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0)), &buffer);
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

    var corrupt_buffer: [4]u8 = @splat(0);
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &corrupt_buffer,
    });
    try std.testing.expect(!std.mem.eql(u8, "abcd", &corrupt_buffer));

    try disk.control().setFaults(.{});
    var clean_buffer: [4]u8 = @splat(0);
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

    var buffer: [4]u8 = @splat(0);
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

    var buffer_a: [4]u8 = @splat(0);
    disk_a.read(.{ .path = "wal.log", .offset = 0, .buffer = &buffer_a }) catch |err| switch (err) {
        error.ReadError => {},
        else => return err,
    };

    var buffer_b: [4]u8 = @splat(0);
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

    var buffer: [4]u8 = @splat(0);
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualStrings("abcd", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.sync op=1 path=wal.log status=ok committed_writes=1 latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash pending_writes=0 landed=0 lost=0 torn=0") != null);
}

test "disk: crash can lose file metadata without directory sync" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.sync(.{ .path = "wal.log" });
    try std.testing.expectEqual(@as(u64, 4), (try disk.stat(.{ .path = "wal.log" })).size);

    try disk.control().setFaults(.{ .crash_lost_metadata_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    try std.testing.expectError(error.FileNotFound, disk.stat(.{ .path = "wal.log" }));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=0 path=. kind=crash_lost_metadata rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash_metadata op=0 dir=. kind=create result=lost") != null);
}

test "disk: directory sync makes file metadata survive crash" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.sync(.{ .path = "wal.log" });
    try disk.syncDir(.{ .path = "." });
    try disk.control().setFaults(.{ .crash_lost_metadata_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    try std.testing.expectEqual(@as(u64, 4), (try disk.stat(.{ .path = "wal.log" })).size);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.sync_dir op=2 path=. status=ok committed_metadata=1 latency_ns=10") != null);
}

test "disk: crash can roll back unsynced delete and rename metadata" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.sync(.{ .path = "wal.log" });
    try disk.syncDir(.{ .path = "." });

    try disk.rename(.{ .old_path = "wal.log", .new_path = "archive/wal.log" });
    try disk.control().setFaults(.{ .crash_lost_metadata_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    try std.testing.expectEqual(@as(u64, 4), (try disk.stat(.{ .path = "wal.log" })).size);
    try std.testing.expectError(error.FileNotFound, disk.stat(.{ .path = "archive/wal.log" }));

    try disk.control().setFaults(.{});
    try disk.rename(.{ .old_path = "wal.log", .new_path = "archive/wal.log" });
    try disk.syncDir(.{ .path = "." });
    try disk.syncDir(.{ .path = "archive" });
    try disk.delete(.{ .path = "archive/wal.log" });
    try disk.control().setFaults(.{ .crash_lost_metadata_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    try std.testing.expectEqual(@as(u64, 4), (try disk.stat(.{ .path = "archive/wal.log" })).size);
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

    var buffer: [4]u8 = @splat(0xff);
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0)), &buffer);
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

    var buffer: [4]u8 = @splat(0);
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

test "disk: crash can reorder unflushed pending writes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "1111" });
    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "2222" });
    try disk.control().setFaults(.{ .crash_reordered_write_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    var buffer: [4]u8 = @splat(0);
    try disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualStrings("1111", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=0 path=wal.log kind=crash_reordered_write rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash_write op=1 path=wal.log offset=0 len=4 result=reordered") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash pending_writes=2 landed=0 lost=0 torn=0 reordered=2") != null);
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

    var buffer: [4]u8 = @splat(0);
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
