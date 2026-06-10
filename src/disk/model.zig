//! App-facing disk capability, options, operations, and shared errors.

const std = @import("std");

const clock_module = @import("../clock.zig");
const env_module = @import("../env.zig");

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
} || std.mem.Allocator.Error || @import("../world.zig").TraceError;

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

pub fn validateByteRange(offset: u64, len: usize) DiskError!void {
    const len_u64: u64 = @intCast(len);
    if (std.math.maxInt(u64) - offset < len_u64) return error.InvalidRange;
}
