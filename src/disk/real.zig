//! Production adapter for Marionette's disk capability.

const std = @import("std");
const model = @import("model.zig");

const Disk = model.Disk;
const DiskError = model.DiskError;
const validateByteRange = model.validateByteRange;
const validateLogicalPath = model.validateLogicalPath;

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
        if (options.logical_len) |logical_len| {
            file.setLength(self.io, logical_len) catch |err| {
                return mapSetLengthError(err);
            };
        }
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

    fn syncDir(_: *Self, options: Disk.SyncDir) DiskError!void {
        try validateLogicalPath(options.path, .directory);
        // Zig 0.16's std.Io has no directory-sync operation. Calling fileSync
        // on a directory handle is backend/platform-specific and can panic on
        // errors that File.sync considers unreachable, so fail explicitly
        // rather than claiming directory-entry durability.
        return error.DirectorySyncUnsupported;
    }

    fn stat(self: *Self, options: Disk.Stat) DiskError!Disk.StatResult {
        try self.validatePath(options.path);
        const file_stat = self.root.statFile(self.io, options.path, .{}) catch |err| {
            return mapStatError(err);
        };
        return .{ .inode = file_stat.inode, .size = file_stat.size };
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

    fn createDir(self: *Self, options: Disk.CreateDir) DiskError!void {
        try validateLogicalPath(options.path, .directory);
        if (std.mem.eql(u8, options.path, ".")) return error.PathAlreadyExists;
        self.root.createDir(self.io, options.path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => return error.PathAlreadyExists,
            error.FileNotFound => return error.FileNotFound,
            error.NotDir => return error.NotDir,
            else => return mapCreateDirError(err),
        };
    }

    fn statDir(self: *Self, options: Disk.StatDir) DiskError!Disk.StatDirResult {
        try validateLogicalPath(options.path, .directory);
        const dir_stat = self.root.statFile(self.io, options.path, .{}) catch |err| {
            return mapStatError(err);
        };
        if (dir_stat.kind != .directory) return error.NotDir;
        return .{
            .inode = dir_stat.inode,
            .mtime_ns = 0,
        };
    }

    fn readDir(self: *Self, options: Disk.ReadDir) DiskError!Disk.DirList {
        try validateLogicalPath(options.path, .directory);
        var dir = self.root.openDir(self.io, options.path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            error.NotDir => return error.NotDir,
            else => return mapOpenReadError(err),
        };
        defer dir.close(self.io);

        var entries: std.ArrayList(Disk.DirEntry) = .empty;
        errdefer {
            for (entries.items) |entry| options.allocator.free(entry.name);
            entries.deinit(options.allocator);
        }
        var iterator = dir.iterate();
        while (iterator.next(self.io) catch return error.ReadError) |entry| {
            const kind: Disk.DirEntryKind = switch (entry.kind) {
                .file => .file,
                .directory => .directory,
                else => continue,
            };
            try entries.append(options.allocator, .{
                .name = try options.allocator.dupe(u8, entry.name),
                .kind = kind,
                .inode = entry.inode,
            });
        }
        return .{
            .allocator = options.allocator,
            .entries = try entries.toOwnedSlice(options.allocator),
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
        try validateLogicalPath(path, .file);
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
        .create_dir = diskCreateDir,
        .stat_dir = diskStatDir,
        .read_dir = diskReadDir,
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

    fn diskCreateDir(ptr: *anyopaque, options: Disk.CreateDir) DiskError!void {
        try fromOpaque(ptr).createDir(options);
    }

    fn diskStatDir(ptr: *anyopaque, options: Disk.StatDir) DiskError!Disk.StatDirResult {
        return try fromOpaque(ptr).statDir(options);
    }

    fn diskReadDir(ptr: *anyopaque, options: Disk.ReadDir) DiskError!Disk.DirList {
        return try fromOpaque(ptr).readDir(options);
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
