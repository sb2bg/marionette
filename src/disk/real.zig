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

    /// Static configuration; alignment rules match the simulated disk.
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

    /// Return the app-facing disk handle over this adapter.
    pub fn disk(self: *Self) Disk {
        return .{ .ptr = self, .vtable = &disk_vtable };
    }

    /// No-op; the caller owns the root directory and host I/O.
    pub fn deinit(_: *Self) void {}

    fn read(self: *Self, options: Disk.Read) DiskError!void {
        try self.validatePath(options.path);
        try self.validateRange(options.offset, options.buffer.len);

        @memset(options.buffer, 0);

        var parent = self.openParent(options.path, false) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer parent.deinit(self.io);

        var file = parent.dir.openFile(self.io, parent.name, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
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

        var parent = try self.openParent(options.path, true);
        defer parent.deinit(self.io);

        var file = try self.openOrCreateFile(parent.dir, parent.name);
        defer file.close(self.io);
        const size_before = if (options.logical_len != null)
            (file.stat(self.io) catch return error.ReadError).size
        else
            0;

        file.writePositionalAll(self.io, options.bytes, options.offset) catch |err| {
            return mapWriteError(err);
        };
        if (options.logical_len) |logical_len| {
            const stat_result = file.stat(self.io) catch return error.ReadError;
            if (logical_len > stat_result.size or (logical_len < stat_result.size and size_before <= logical_len)) {
                file.setLength(self.io, logical_len) catch |err| {
                    return mapSetLengthError(err);
                };
            }
        }
    }

    fn sync(self: *Self, options: Disk.Sync) DiskError!void {
        try self.validatePath(options.path);

        var parent = self.openParent(options.path, false) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer parent.deinit(self.io);

        var file = parent.dir.openFile(self.io, parent.name, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
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

        var parent = try self.openParent(options.path, false);
        defer parent.deinit(self.io);
        var file = parent.dir.openFile(self.io, parent.name, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return mapOpenReadError(err),
        };
        defer file.close(self.io);
        const file_stat = file.stat(self.io) catch return error.ReadError;
        return .{ .inode = file_stat.inode, .size = file_stat.size };
    }

    fn readSome(self: *Self, options: Disk.ReadSome) DiskError!usize {
        try self.validatePath(options.path);
        try validateByteRange(options.offset, options.buffer.len);

        var parent = try self.openParent(options.path, false);
        defer parent.deinit(self.io);

        var file = parent.dir.openFile(self.io, parent.name, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
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

        var parent = try self.openParent(options.path, false);
        defer parent.deinit(self.io);

        var file = parent.dir.openFile(self.io, parent.name, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
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

        var parent = try self.openParent(options.path, false);
        defer parent.deinit(self.io);
        try self.rejectSymlink(parent.dir, parent.name, false);
        parent.dir.deleteFile(self.io, parent.name) catch |err| {
            return mapDeleteError(err);
        };
    }

    fn rename(self: *Self, options: Disk.Rename) DiskError!void {
        try self.validatePath(options.old_path);
        try self.validatePath(options.new_path);

        var old_parent = try self.openParent(options.old_path, false);
        defer old_parent.deinit(self.io);
        var new_parent = try self.openParent(options.new_path, true);
        defer new_parent.deinit(self.io);
        try self.rejectSymlink(old_parent.dir, old_parent.name, false);
        try self.rejectSymlink(new_parent.dir, new_parent.name, true);
        std.Io.Dir.rename(old_parent.dir, old_parent.name, new_parent.dir, new_parent.name, self.io) catch |err| {
            return mapRenameError(err);
        };
    }

    fn createDir(self: *Self, options: Disk.CreateDir) DiskError!void {
        try validateLogicalPath(options.path, .directory);
        if (std.mem.eql(u8, options.path, ".")) return error.PathAlreadyExists;

        var parent = try self.openParent(options.path, false);
        defer parent.deinit(self.io);
        parent.dir.createDir(self.io, parent.name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => return error.PathAlreadyExists,
            error.FileNotFound => return error.FileNotFound,
            error.NotDir => return error.NotDir,
            else => return mapCreateDirError(err),
        };
    }

    fn statDir(self: *Self, options: Disk.StatDir) DiskError!Disk.StatDirResult {
        try validateLogicalPath(options.path, .directory);

        if (std.mem.eql(u8, options.path, ".")) {
            const dir_stat = self.root.stat(self.io) catch return error.ReadError;
            return .{ .inode = dir_stat.inode, .mtime_ns = 0 };
        }
        var parent = try self.openParent(options.path, false);
        defer parent.deinit(self.io);
        try self.rejectSymlink(parent.dir, parent.name, false);
        var dir = parent.dir.openDir(self.io, parent.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            error.NotDir => return error.NotDir,
            else => return mapOpenReadError(err),
        };
        defer dir.close(self.io);
        const dir_stat = dir.stat(self.io) catch return error.ReadError;
        return .{
            .inode = dir_stat.inode,
            .mtime_ns = 0,
        };
    }

    fn readDir(self: *Self, options: Disk.ReadDir) DiskError!Disk.DirList {
        try validateLogicalPath(options.path, .directory);

        var parent: ?Parent = null;
        var dir = if (std.mem.eql(u8, options.path, "."))
            self.root.openDir(self.io, ".", .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch |err| return mapOpenReadError(err)
        else blk: {
            var opened_parent = try self.openParent(options.path, false);
            var transfer_parent = false;
            defer if (!transfer_parent) opened_parent.deinit(self.io);
            try self.rejectSymlink(opened_parent.dir, opened_parent.name, false);
            const opened_dir = opened_parent.dir.openDir(self.io, opened_parent.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch |err| switch (err) {
                error.FileNotFound => return error.FileNotFound,
                error.NotDir => return error.NotDir,
                else => return mapOpenReadError(err),
            };
            parent = opened_parent;
            transfer_parent = true;
            break :blk opened_dir;
        };
        defer if (parent) |*opened_parent| opened_parent.deinit(self.io);
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

    const Parent = struct {
        dir: std.Io.Dir,
        name: []const u8,
        owned: bool,

        fn deinit(parent: *Parent, io: std.Io) void {
            if (parent.owned) parent.dir.close(io);
        }
    };

    fn openParent(self: *Self, path: []const u8, create: bool) DiskError!Parent {
        const parent_path = std.fs.path.dirname(path) orelse return .{
            .dir = self.root,
            .name = path,
            .owned = false,
        };

        var current = self.root;
        var current_owned = false;
        errdefer if (current_owned) current.close(self.io);

        var components = std.mem.splitScalar(u8, parent_path, '/');
        while (components.next()) |component| {
            const next = current.openDir(self.io, component, .{
                .follow_symlinks = false,
            }) catch |err| switch (err) {
                error.FileNotFound => if (create) create_dir: {
                    current.createDir(self.io, component, .default_dir) catch |create_err| switch (create_err) {
                        error.PathAlreadyExists => {},
                        else => return mapCreateDirError(create_err),
                    };
                    break :create_dir current.openDir(self.io, component, .{
                        .follow_symlinks = false,
                    }) catch |open_err| return mapParentOpenError(open_err);
                } else return error.FileNotFound,
                else => return mapParentOpenError(err),
            };
            if (current_owned) current.close(self.io);
            current = next;
            current_owned = true;
        }
        return .{
            .dir = current,
            .name = std.fs.path.basename(path),
            .owned = current_owned,
        };
    }

    fn openOrCreateFile(self: *Self, parent: std.Io.Dir, name: []const u8) DiskError!std.Io.File {
        return parent.openFile(self.io, name, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => parent.createFile(self.io, name, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .resolve_beneath = true,
            }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => parent.openFile(self.io, name, .{
                    .mode = .read_write,
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                }) catch |open_err| return mapOpenWriteError(open_err),
                else => return mapOpenWriteError(create_err),
            },
            else => return mapOpenWriteError(err),
        };
    }

    fn rejectSymlink(self: *Self, parent: std.Io.Dir, name: []const u8, allow_missing: bool) DiskError!void {
        const file_stat = parent.statFile(self.io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => if (allow_missing) return else return error.FileNotFound,
            else => return mapStatError(err),
        };
        if (file_stat.kind == .sym_link) return error.InvalidPath;
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

fn mapParentOpenError(err: std.Io.Dir.OpenError) DiskError {
    return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
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

test "disk: real disk logical_len trims padding without truncating existing bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try RealDisk.init(tmp.dir, std.testing.io, .{ .sector_size = 4 });
    defer disk.deinit();
    const app_disk = disk.disk();

    try app_disk.write(.{
        .path = "short.bin",
        .offset = 0,
        .bytes = "abcd",
        .logical_len = 2,
    });
    try std.testing.expectEqual(@as(u64, 2), (try app_disk.stat(.{ .path = "short.bin" })).size);

    try app_disk.write(.{
        .path = "data.bin",
        .offset = 0,
        .bytes = "abcdefgh",
    });
    try std.testing.expectEqual(@as(u64, 8), (try app_disk.stat(.{ .path = "data.bin" })).size);

    try app_disk.write(.{
        .path = "data.bin",
        .offset = 0,
        .bytes = "WXYZ",
        .logical_len = 4,
    });
    try std.testing.expectEqual(@as(u64, 8), (try app_disk.stat(.{ .path = "data.bin" })).size);

    try app_disk.write(.{
        .path = "data.bin",
        .offset = 8,
        .bytes = "ijkl",
        .logical_len = 12,
    });
    try std.testing.expectEqual(@as(u64, 12), (try app_disk.stat(.{ .path = "data.bin" })).size);
}

test "disk: real disk rejects symlink escapes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "root", .default_dir);
    try tmp.dir.createDir(std.testing.io, "outside", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "outside/secret.bin",
        .data = "safe",
    });
    try tmp.dir.symLink(std.testing.io, "../outside/secret.bin", "root/file-link", .{});
    try tmp.dir.symLink(std.testing.io, "../outside", "root/dir-link", .{ .is_directory = true });

    var root = try tmp.dir.openDir(std.testing.io, "root", .{});
    defer root.close(std.testing.io);
    var disk = try RealDisk.init(root, std.testing.io, .{ .sector_size = 4 });
    defer disk.deinit();
    const app_disk = disk.disk();

    var aligned: [4]u8 = undefined;
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidPath, app_disk.read(.{
        .path = "file-link",
        .offset = 0,
        .buffer = &aligned,
    }));
    try std.testing.expectError(error.InvalidPath, app_disk.write(.{
        .path = "file-link",
        .offset = 0,
        .bytes = "evil",
    }));
    try std.testing.expectError(error.InvalidPath, app_disk.sync(.{ .path = "file-link" }));
    try std.testing.expectError(error.InvalidPath, app_disk.stat(.{ .path = "file-link" }));
    try std.testing.expectError(error.InvalidPath, app_disk.readSome(.{
        .path = "file-link",
        .offset = 0,
        .buffer = &byte,
    }));
    try std.testing.expectError(error.InvalidPath, app_disk.setLength(.{
        .path = "file-link",
        .len = 0,
    }));
    try std.testing.expectError(error.InvalidPath, app_disk.delete(.{ .path = "file-link" }));
    try std.testing.expectError(error.InvalidPath, app_disk.rename(.{
        .old_path = "file-link",
        .new_path = "renamed.bin",
    }));
    try app_disk.write(.{ .path = "normal.bin", .offset = 0, .bytes = "good" });
    try std.testing.expectError(error.InvalidPath, app_disk.rename(.{
        .old_path = "normal.bin",
        .new_path = "file-link",
    }));

    try std.testing.expectError(error.InvalidPath, app_disk.read(.{
        .path = "dir-link/secret.bin",
        .offset = 0,
        .buffer = &aligned,
    }));
    try std.testing.expectError(error.InvalidPath, app_disk.write(.{
        .path = "dir-link/new.bin",
        .offset = 0,
        .bytes = "evil",
    }));
    try std.testing.expectError(error.InvalidPath, app_disk.createDir(.{ .path = "dir-link/new" }));
    try std.testing.expectError(error.InvalidPath, app_disk.statDir(.{ .path = "dir-link" }));
    try std.testing.expectError(error.InvalidPath, app_disk.readDir(.{
        .path = "dir-link",
        .allocator = std.testing.allocator,
    }));

    var normal: [4]u8 = undefined;
    try app_disk.read(.{ .path = "normal.bin", .offset = 0, .buffer = &normal });
    try std.testing.expectEqualStrings("good", &normal);

    var outside: [4]u8 = undefined;
    var outside_file = try tmp.dir.openFile(std.testing.io, "outside/secret.bin", .{});
    defer outside_file.close(std.testing.io);
    try std.testing.expectEqual(@as(usize, 4), try outside_file.readPositionalAll(std.testing.io, &outside, 0));
    try std.testing.expectEqualStrings("safe", &outside);
    try std.testing.expectEqual(.sym_link, (try root.statFile(std.testing.io, "file-link", .{
        .follow_symlinks = false,
    })).kind);
}
