//! App-facing disk capability, options, operations, and shared errors.

const std = @import("std");

const clock_module = @import("../clock.zig");
const env_module = @import("../env.zig");

/// Versioned simulator semantics applications may rely on.
///
/// `portable_v1` is deliberately a Marionette contract rather than a claim
/// about any one host filesystem. It uses sector-prefix tears, one
/// crash-global reversal for surviving writes, and commits a path's pending
/// writes before `setLength`, `delete`, or `rename` changes its lifecycle.
pub const DiskSemanticContract = enum {
    portable_v1,
};

pub const disk_semantic_contract: DiskSemanticContract = .portable_v1;
pub const disk_semantic_version: u32 = 1;

/// Errors shared by every disk implementation and control operation.
pub const DiskError = error{
    DiskUnavailable,
    FileNotFound,
    PathAlreadyExists,
    NotDir,
    IsDir,
    InvalidAlignment,
    InvalidDuration,
    InvalidPath,
    InvalidRate,
    InvalidRange,
    DirectorySyncUnsupported,
    DiskCrashed,
    ReadError,
    WriteError,
} || std.mem.Allocator.Error || @import("../world.zig").TraceError;

/// Scheduler hook used by `SimDisk` to suspend task-side operations until
/// their simulated completion deadline without depending on the scheduler
/// module directly.
pub const DiskLatencyRuntime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        in_task: *const fn (ptr: *anyopaque) bool,
        wait_until: *const fn (ptr: *anyopaque, deadline_ns: clock_module.Timestamp) void,
    };

    pub fn inTask(self: DiskLatencyRuntime) bool {
        return self.vtable.in_task(self.ptr);
    }

    pub fn waitUntil(self: DiskLatencyRuntime, deadline_ns: clock_module.Timestamp) void {
        self.vtable.wait_until(self.ptr, deadline_ns);
    }
};

/// Static simulated-disk configuration passed to `World.simulate`.
pub const DiskOptions = struct {
    /// Sector size in bytes; offsets and lengths must align to it.
    sector_size: u64 = 4096,
    /// Base per-operation latency. Defaults to one world tick; both
    /// latency values must be tick-aligned.
    min_latency_ns: ?clock_module.Duration = null,
    /// Maximum additional seeded per-operation jitter.
    latency_jitter_ns: clock_module.Duration = 0,
};

/// Probabilistic disk fault rates, set through `control.disk.setFaults`.
/// The `crash_*` classes apply only to writes and metadata still pending at
/// a crash; they never damage durable truth (see the disk fault model doc).
pub const DiskFaultOptions = struct {
    /// Per-operation chance a read fails with `error.ReadError`.
    read_error_rate: env_module.BuggifyRate = .never(),
    /// Per-operation chance a write fails with `error.WriteError`.
    write_error_rate: env_module.BuggifyRate = .never(),
    /// Per-operation chance a read returns corrupted sector bytes.
    corrupt_read_rate: env_module.BuggifyRate = .never(),
    /// Per-pending-write chance the write vanishes at a crash.
    crash_lost_write_rate: env_module.BuggifyRate = .never(),
    /// Per-pending-write chance only a prefix of sectors lands at a crash.
    crash_torn_write_rate: env_module.BuggifyRate = .never(),
    /// Per-surviving-write chance to trigger a crash-global reversal.
    crash_reordered_write_rate: env_module.BuggifyRate = .never(),
    /// Per-pending-metadata chance a directory operation rolls back at a crash.
    crash_lost_metadata_rate: env_module.BuggifyRate = .never(),
};

/// App-facing disk capability handle. Apps receive it as `Env.disk`;
/// simulation backs it with `SimDisk` (deterministic latency, faults, and
/// crash semantics) and production backs it with `RealDisk`. Offsets and
/// lengths must be sector-aligned (`error.InvalidAlignment`), and paths use
/// rooted, non-traversing logical syntax (`error.InvalidPath`).
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
    pub const CreateDir = DiskCreateDir;
    pub const StatDir = DiskStatDir;
    pub const StatDirResult = DiskStatDirResult;
    pub const ReadDir = DiskReadDir;
    pub const DirEntry = DiskDirEntry;
    pub const DirEntryKind = DiskDirEntryKind;
    pub const DirList = DiskDirList;
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
        create_dir: *const fn (*anyopaque, CreateDir) DiskError!void,
        stat_dir: *const fn (*anyopaque, StatDir) DiskError!StatDirResult,
        read_dir: *const fn (*anyopaque, ReadDir) DiskError!DirList,
    };

    /// Fill `options.buffer` from sector-aligned `options.offset`,
    /// zero-filling past the current logical file size.
    pub fn read(self: Disk, options: Read) DiskError!void {
        try self.vtable.read(self.ptr, options);
    }

    /// Write sector-aligned bytes. In simulation the write is pending,
    /// vulnerable to crash fault classes, until a `sync` commits it.
    pub fn write(self: Disk, options: Write) DiskError!void {
        try self.vtable.write(self.ptr, options);
    }

    /// Commit one file's pending writes to durable truth. Directory
    /// metadata needs `syncDir` separately.
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

    /// Report one file's logical size and existence.
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

    /// Truncate or extend one file's logical size.
    pub fn setLength(self: Disk, options: SetLength) DiskError!void {
        try self.vtable.set_length(self.ptr, options);
    }

    /// Delete one file. Durable only after `syncDir` on its directory.
    pub fn delete(self: Disk, options: Delete) DiskError!void {
        try self.vtable.delete(self.ptr, options);
    }

    /// Atomically rename one file, replacing any existing target.
    /// Durable only after `syncDir` on the affected directories.
    pub fn rename(self: Disk, options: Rename) DiskError!void {
        try self.vtable.rename(self.ptr, options);
    }

    /// Create one directory. Durable only after `syncDir` on its parent.
    pub fn createDir(self: Disk, options: CreateDir) DiskError!void {
        try self.vtable.create_dir(self.ptr, options);
    }

    /// Report one directory's existence.
    pub fn statDir(self: Disk, options: StatDir) DiskError!StatDirResult {
        return try self.vtable.stat_dir(self.ptr, options);
    }

    /// List one directory's direct children. Simulation returns a
    /// deterministic order; production returns the host's order. The
    /// caller owns the returned list and must `deinit` it.
    pub fn readDir(self: Disk, options: ReadDir) DiskError!DirList {
        return try self.vtable.read_dir(self.ptr, options);
    }

    /// A disk whose every operation returns `error.DiskUnavailable`.
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
    .create_dir = unavailableCreateDir,
    .stat_dir = unavailableStatDir,
    .read_dir = unavailableReadDir,
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

fn unavailableCreateDir(_: *anyopaque, _: Disk.CreateDir) DiskError!void {
    return error.DiskUnavailable;
}

fn unavailableStatDir(_: *anyopaque, _: Disk.StatDir) DiskError!Disk.StatDirResult {
    return error.DiskUnavailable;
}

fn unavailableReadDir(_: *anyopaque, _: Disk.ReadDir) DiskError!Disk.DirList {
    return error.DiskUnavailable;
}

pub const DiskRead = struct {
    path: []const u8,
    offset: u64,
    buffer: []u8,
};

pub const DiskWrite = struct {
    path: []const u8,
    offset: u64,
    bytes: []const u8,
    /// Logical file length after this physical write. Sector adapters use
    /// this when a short application write is represented by a full-sector
    /// read-modify-write.
    logical_len: ?u64 = null,
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
    inode: u64,
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

pub const DiskCreateDir = struct {
    path: []const u8,
};

pub const DiskStatDir = struct {
    path: []const u8,
};

pub const DiskStatDirResult = struct {
    inode: u64,
    mtime_ns: u64,
};

pub const DiskReadDir = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
};

pub const DiskDirEntryKind = enum {
    file,
    directory,
};

pub const DiskDirEntry = struct {
    name: []u8,
    kind: DiskDirEntryKind,
    inode: u64,
};

pub const DiskDirList = struct {
    allocator: std.mem.Allocator,
    entries: []DiskDirEntry,

    pub fn deinit(self: *DiskDirList) void {
        for (self.entries) |entry| self.allocator.free(entry.name);
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const DiskCrash = struct {};

pub const DiskRestart = struct {};

/// Logical path role within a rooted Marionette disk namespace.
pub const LogicalPathKind = enum {
    file,
    directory,
};

/// Validate canonical path syntax in Marionette's rooted namespace.
///
/// File paths use non-empty `/`-separated components. Empty, `.`, and `..`
/// components, host absolute paths, Windows drive roots, backslashes, and NUL
/// bytes are rejected. Directory paths follow the same rules, except that `.`
/// names the logical root for operations such as `Disk.syncDir`.
pub fn validateLogicalPath(path: []const u8, kind: LogicalPathKind) DiskError!void {
    if (kind == .directory and std.mem.eql(u8, path, ".")) return;
    if (path.len == 0) return error.InvalidPath;
    if (path[0] == '/') return error.InvalidPath;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
        return error.InvalidPath;
    }
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidPath;

    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, component, ".")) return error.InvalidPath;
        if (std.mem.eql(u8, component, "..")) return error.InvalidPath;
    }
}

pub fn validateByteRange(offset: u64, len: usize) DiskError!void {
    const len_u64: u64 = @intCast(len);
    if (std.math.maxInt(u64) - offset < len_u64) return error.InvalidRange;
}

test "disk model: logical paths use canonical rooted syntax" {
    try validateLogicalPath("wal.log", .file);
    try validateLogicalPath("archive/wal.log", .file);
    try validateLogicalPath(".", .directory);
    try validateLogicalPath("archive", .directory);

    const invalid_paths = [_][]const u8{
        "",
        ".",
        "..",
        "archive/./wal.log",
        "archive/../wal.log",
        "archive//wal.log",
        "archive/wal.log/",
        "/wal.log",
        "C:/wal.log",
        "archive\\wal.log",
        "wal\x00.log",
    };
    for (invalid_paths) |path| {
        try std.testing.expectError(error.InvalidPath, validateLogicalPath(path, .file));
    }
}
