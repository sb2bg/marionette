//! `std.Io.File` and flat-directory operations backed by Marionette disk.

const std = @import("std");

const disk_module = @import("../disk/root.zig");
const errors = @import("errors.zig");
const Io = std.Io;

pub fn Ops(comptime Backend: type) type {
    return struct {
        fn backendFromUserdata(userdata: ?*anyopaque) *Backend {
            return @ptrCast(@alignCast(userdata.?));
        }

        pub fn simDirCreateFile(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            options: Io.Dir.CreateFileOptions,
        ) Io.File.OpenError!Io.File {
            _ = dir;
            if (options.lock != .none) return error.FileLocksUnsupported;
            disk_module.validateLogicalPath(sub_path, .file) catch return error.FileNotFound;

            const backend = backendFromUserdata(userdata);
            const existing_index = findOrDiscoverFileMeta(backend, sub_path) catch |err| {
                return errors.mapDiskOpenError(err);
            };
            const file_index = if (existing_index) |index| b: {
                if (options.exclusive) return error.PathAlreadyExists;
                if (options.truncate) {
                    const old_len = backend.files.items[index].len;
                    backend.disk.setLength(.{ .path = sub_path, .len = 0 }) catch |err| switch (err) {
                        error.FileNotFound => {},
                        else => return errors.mapDiskOpenError(err),
                    };
                    backend.files.items[index].len = 0;
                    if (old_len != 0) backend.files.items[index].mtime = backend.nowTimestamp();
                }
                break :b index;
            } else b: {
                backend.disk.write(.{ .path = sub_path, .offset = 0, .bytes = &.{} }) catch |err| {
                    return errors.mapDiskOpenError(err);
                };
                break :b backend.createFileMeta(sub_path) catch return error.SystemResources;
            };

            return backend.openFileHandle(file_index, options.read, true) catch return error.SystemResources;
        }

        pub fn simDirOpenFile(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            options: Io.Dir.OpenFileOptions,
        ) Io.File.OpenError!Io.File {
            _ = dir;
            _ = options.allow_directory;
            if (options.path_only) return error.AccessDenied;
            if (options.lock != .none) return error.FileLocksUnsupported;
            disk_module.validateLogicalPath(sub_path, .file) catch return error.FileNotFound;

            const backend = backendFromUserdata(userdata);
            const file_index = (findOrDiscoverFileMeta(backend, sub_path) catch |err| {
                return errors.mapDiskOpenError(err);
            }) orelse return error.FileNotFound;
            return backend.openFileHandle(file_index, options.isRead(), options.isWrite()) catch return error.SystemResources;
        }

        pub fn simDirClose(userdata: ?*anyopaque, dirs: []const Io.Dir) void {
            _ = userdata;
            _ = dirs;
        }

        pub fn simDirStatFile(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            options: Io.Dir.StatFileOptions,
        ) Io.Dir.StatFileError!Io.File.Stat {
            _ = dir;
            _ = options.follow_symlinks;
            disk_module.validateLogicalPath(sub_path, .file) catch return error.FileNotFound;

            const backend = backendFromUserdata(userdata);
            // Discovery failures other than not-found collapse to
            // FileNotFound here: StatFileError has no closer member for a
            // crashed or unavailable disk.
            const file_index = (findOrDiscoverFileMeta(backend, sub_path) catch {
                return error.FileNotFound;
            }) orelse return error.FileNotFound;
            return buildFileStat(backend, file_index);
        }

        pub fn simDirAccess(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            options: Io.Dir.AccessOptions,
        ) Io.Dir.AccessError!void {
            _ = dir;
            if (options.execute) return error.AccessDenied;
            disk_module.validateLogicalPath(sub_path, .file) catch return error.FileNotFound;

            const backend = backendFromUserdata(userdata);
            _ = (findOrDiscoverFileMeta(backend, sub_path) catch {
                return error.FileNotFound;
            }) orelse return error.FileNotFound;
        }

        pub fn simDirDeleteFile(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
        ) Io.Dir.DeleteFileError!void {
            _ = dir;
            disk_module.validateLogicalPath(sub_path, .file) catch return error.FileNotFound;

            const backend = backendFromUserdata(userdata);
            const file_index = (findOrDiscoverFileMeta(backend, sub_path) catch |err| {
                return errors.mapDiskDeleteError(err);
            }) orelse return error.FileNotFound;
            backend.disk.delete(.{ .path = sub_path }) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return errors.mapDiskDeleteError(err),
            };

            backend.closeFileHandlesForIndex(file_index);
            backend.files.items[file_index].deleted = true;
            backend.files.items[file_index].len = 0;
        }

        pub fn simDirRename(
            userdata: ?*anyopaque,
            old_dir: Io.Dir,
            old_sub_path: []const u8,
            new_dir: Io.Dir,
            new_sub_path: []const u8,
        ) Io.Dir.RenameError!void {
            _ = old_dir;
            _ = new_dir;
            disk_module.validateLogicalPath(old_sub_path, .file) catch return error.FileNotFound;
            disk_module.validateLogicalPath(new_sub_path, .file) catch return error.FileNotFound;

            const backend = backendFromUserdata(userdata);
            const old_index = (findOrDiscoverFileMeta(backend, old_sub_path) catch |err| {
                return errors.mapDiskRenameError(err);
            }) orelse return error.FileNotFound;
            if (std.mem.eql(u8, old_sub_path, new_sub_path)) return;

            const new_index = backend.findFileMetaIndex(new_sub_path);
            const owned_path = backend.allocator.dupe(u8, new_sub_path) catch return error.SystemResources;
            errdefer backend.allocator.free(owned_path);

            backend.disk.rename(.{ .old_path = old_sub_path, .new_path = new_sub_path }) catch |err| switch (err) {
                error.FileNotFound => {
                    if (backend.files.items[old_index].len != 0) return error.FileNotFound;
                },
                else => return errors.mapDiskRenameError(err),
            };

            if (new_index) |index| {
                backend.closeFileHandlesForIndex(index);
                backend.files.items[index].deleted = true;
                backend.files.items[index].len = 0;
            }

            backend.allocator.free(backend.files.items[old_index].path);
            backend.files.items[old_index].path = owned_path;
        }

        pub fn simFileStat(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.AccessDenied;
            if (state.closed or backend.fileMeta(state).deleted) return error.AccessDenied;
            return buildFileStat(backend, state.file_index);
        }

        fn buildFileStat(backend: *Backend, file_index: usize) Io.File.Stat {
            const meta = &backend.files.items[file_index];
            return .{
                .inode = @intCast(file_index + 1),
                .nlink = 1,
                .size = meta.len,
                .permissions = .default_file,
                .kind = .file,
                .atime = .zero,
                .mtime = meta.mtime,
                .ctime = .zero,
                .block_size = @intCast(@min(backend.sector_size, std.math.maxInt(Io.File.BlockSize))),
            };
        }

        pub fn simFileLength(userdata: ?*anyopaque, file: Io.File) Io.File.LengthError!u64 {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.AccessDenied;
            if (state.closed or backend.fileMeta(state).deleted) return error.AccessDenied;
            return backend.fileMeta(state).len;
        }

        pub fn simFileClose(userdata: ?*anyopaque, files: []const Io.File) void {
            const backend = backendFromUserdata(userdata);
            for (files) |file| {
                backend.retireFileHandle(file.handle);
            }
        }

        pub fn simFileReadPositional(
            userdata: ?*anyopaque,
            file: Io.File,
            data: []const []u8,
            offset: u64,
        ) Io.File.ReadPositionalError!usize {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.NotOpenForReading;
            if (state.closed or !state.read or backend.fileMeta(state).deleted) return error.NotOpenForReading;

            const meta = backend.fileMeta(state);
            if (offset >= meta.len) return 0;

            var cursor = offset;
            var total: usize = 0;
            for (data) |buffer| {
                if (buffer.len == 0) continue;
                if (cursor >= meta.len) break;
                const available = @min(@as(u64, @intCast(buffer.len)), meta.len - cursor);
                const read_len: usize = @intCast(available);
                readDiskBytes(backend, meta.path, buffer[0..read_len], cursor) catch |err| return errors.mapDiskReadError(err);
                cursor += read_len;
                total += read_len;
                if (read_len < buffer.len) break;
            }
            return total;
        }

        pub fn simFileWritePositional(
            userdata: ?*anyopaque,
            file: Io.File,
            header: []const u8,
            data: []const []const u8,
            splat: usize,
            offset: u64,
        ) Io.File.WritePositionalError!usize {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.NotOpenForWriting;
            if (state.closed or !state.write or backend.fileMeta(state).deleted) return error.NotOpenForWriting;

            const meta = backend.fileMeta(state);
            var cursor = offset;
            var total: usize = 0;

            writePart(backend, meta, header, &cursor, &total) catch |err| return errors.mapDiskWriteError(err);
            if (data.len > 0) {
                for (data[0 .. data.len - 1]) |bytes| {
                    writePart(backend, meta, bytes, &cursor, &total) catch |err| return errors.mapDiskWriteError(err);
                }
                const pattern = data[data.len - 1];
                for (0..splat) |_| {
                    writePart(backend, meta, pattern, &cursor, &total) catch |err| return errors.mapDiskWriteError(err);
                }
            }
            if (total != 0) meta.mtime = backend.nowTimestamp();
            return total;
        }

        pub fn simFileReadStreaming(
            userdata: ?*anyopaque,
            file: Io.File,
            data: []const []u8,
        ) Io.Operation.FileReadStreaming.Result {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.NotOpenForReading;
            if (state.closed or !state.read or backend.fileMeta(state).deleted) return error.NotOpenForReading;

            const read_len = simFileReadPositional(userdata, file, data, state.cursor) catch |err| switch (err) {
                error.NotOpenForReading => return error.NotOpenForReading,
                error.AccessDenied => return error.AccessDenied,
                error.SystemResources => return error.SystemResources,
                error.WouldBlock => return error.WouldBlock,
                error.LockViolation => return error.LockViolation,
                error.IsDir => return error.IsDir,
                else => return error.InputOutput,
            };
            if (read_len == 0) return error.EndOfStream;
            state.cursor += read_len;
            return read_len;
        }

        pub fn simFileWriteStreaming(
            userdata: ?*anyopaque,
            file: Io.File,
            header: []const u8,
            data: []const []const u8,
            splat: usize,
        ) Io.Operation.FileWriteStreaming.Result {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.NotOpenForWriting;
            if (state.closed or !state.write or backend.fileMeta(state).deleted) return error.NotOpenForWriting;

            const write_len = simFileWritePositional(userdata, file, header, data, splat, state.cursor) catch |err| switch (err) {
                error.NotOpenForWriting => return error.NotOpenForWriting,
                error.AccessDenied => return error.AccessDenied,
                error.PermissionDenied => return error.PermissionDenied,
                error.SystemResources => return error.SystemResources,
                error.WouldBlock => return error.WouldBlock,
                error.LockViolation => return error.LockViolation,
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.FileTooBig => return error.FileTooBig,
                error.DiskQuota => return error.DiskQuota,
                error.DeviceBusy => return error.DeviceBusy,
                error.BrokenPipe => return error.BrokenPipe,
                error.NoDevice => return error.NoDevice,
                error.FileBusy => return error.FileBusy,
                else => return error.InputOutput,
            };
            state.cursor += write_len;
            return write_len;
        }

        pub fn simFileSeekBy(userdata: ?*anyopaque, file: Io.File, relative_offset: i64) Io.File.SeekError!void {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.AccessDenied;
            if (state.closed or backend.fileMeta(state).deleted) return error.AccessDenied;

            if (relative_offset < 0) {
                if (relative_offset == std.math.minInt(i64)) return error.Unseekable;
                const distance: u64 = @intCast(-relative_offset);
                if (distance > state.cursor) return error.Unseekable;
                state.cursor -= distance;
                return;
            }

            const distance: u64 = @intCast(relative_offset);
            if (std.math.maxInt(u64) - state.cursor < distance) return error.Unseekable;
            state.cursor += distance;
        }

        pub fn simFileSeekTo(userdata: ?*anyopaque, file: Io.File, absolute_offset: u64) Io.File.SeekError!void {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.AccessDenied;
            if (state.closed or backend.fileMeta(state).deleted) return error.AccessDenied;
            state.cursor = absolute_offset;
        }

        pub fn simFileSync(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.AccessDenied;
            if (state.closed or backend.fileMeta(state).deleted) return error.AccessDenied;
            backend.disk.sync(.{ .path = backend.fileMeta(state).path }) catch |err| return errors.mapDiskSyncError(err);
        }

        pub fn simFileSetLength(userdata: ?*anyopaque, file: Io.File, new_length: u64) Io.File.SetLengthError!void {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.AccessDenied;
            if (state.closed or !state.write or backend.fileMeta(state).deleted) return error.AccessDenied;
            const meta = backend.fileMeta(state);
            const old_len = meta.len;
            if (new_length > old_len) {
                zeroDiskBytes(backend, meta.path, old_len, new_length - old_len) catch return error.InputOutput;
            }
            backend.disk.setLength(.{ .path = meta.path, .len = new_length }) catch |err| switch (err) {
                error.FileNotFound => {
                    if (new_length != 0) return error.InputOutput;
                },
                else => return errors.mapDiskSetLengthError(err),
            };
            meta.len = new_length;
            if (new_length != old_len) meta.mtime = backend.nowTimestamp();
        }

        /// Find the cached metadata for `path`, refreshing or rediscovering
        /// it from the disk authority when needed. A disk crash (modeling a
        /// machine crash that kills the process) marks cached metadata
        /// stale, so surviving files land here on first touch after restart
        /// and have their length re-derived from disk truth. Timestamps are
        /// kept across the refresh, matching real filesystems.
        fn findOrDiscoverFileMeta(
            backend: *Backend,
            path: []const u8,
        ) disk_module.DiskError!?usize {
            if (backend.findFileMetaIndex(path)) |index| {
                const meta = &backend.files.items[index];
                if (!meta.stale) return index;

                const stat_result = backend.disk.stat(.{ .path = path }) catch |err| switch (err) {
                    error.FileNotFound, error.DiskUnavailable => {
                        meta.deleted = true;
                        meta.len = 0;
                        meta.stale = false;
                        return null;
                    },
                    else => return err,
                };
                meta.len = stat_result.size;
                meta.stale = false;
                return index;
            }

            // A crash can roll back an unsynced deletion; if the disk still
            // has the file, revive the tombstone so the resurrected file
            // keeps its pre-crash timestamps.
            if (backend.findStaleDeletedFileMetaIndex(path)) |index| {
                const meta = &backend.files.items[index];
                const stat_result = backend.disk.stat(.{ .path = path }) catch |err| switch (err) {
                    error.FileNotFound, error.DiskUnavailable => {
                        meta.stale = false;
                        return null;
                    },
                    else => return err,
                };
                meta.deleted = false;
                meta.stale = false;
                meta.len = stat_result.size;
                return index;
            }

            const stat_result = backend.disk.stat(.{ .path = path }) catch |err| switch (err) {
                error.FileNotFound, error.DiskUnavailable => return null,
                else => return err,
            };
            const index = try backend.createFileMeta(path);
            backend.files.items[index].len = stat_result.size;
            return index;
        }

        fn writePart(
            backend: *Backend,
            meta: *Backend.FileMeta,
            bytes: []const u8,
            cursor: *u64,
            total: *usize,
        ) disk_module.DiskError!void {
            if (bytes.len == 0) return;
            if (cursor.* > meta.len) {
                try zeroDiskBytes(backend, meta.path, meta.len, cursor.* - meta.len);
            }
            try writeDiskBytes(backend, meta.path, bytes, cursor.*);
            const len_u64: u64 = @intCast(bytes.len);
            if (std.math.maxInt(u64) - cursor.* < len_u64) return error.InvalidRange;
            cursor.* += len_u64;
            total.* += bytes.len;
            meta.len = @max(meta.len, cursor.*);
        }

        fn readDiskBytes(
            backend: *Backend,
            path: []const u8,
            dest: []u8,
            offset: u64,
        ) disk_module.DiskError!void {
            if (dest.len == 0) return;
            const sector_size = try sectorSizeUsize(backend);
            var sector = try backend.allocator.alloc(u8, sector_size);
            defer backend.allocator.free(sector);

            var remaining = dest;
            var cursor = offset;
            while (remaining.len > 0) {
                const sector_offset_u64 = cursor % backend.sector_size;
                const sector_offset: usize = @intCast(sector_offset_u64);
                const sector_start = cursor - sector_offset_u64;
                const copy_len = @min(remaining.len, sector_size - sector_offset);

                try backend.disk.read(.{
                    .path = path,
                    .offset = sector_start,
                    .buffer = sector,
                });
                @memcpy(remaining[0..copy_len], sector[sector_offset..][0..copy_len]);

                remaining = remaining[copy_len..];
                cursor += copy_len;
            }
        }

        fn writeDiskBytes(
            backend: *Backend,
            path: []const u8,
            src: []const u8,
            offset: u64,
        ) disk_module.DiskError!void {
            if (src.len == 0) return;
            const sector_size = try sectorSizeUsize(backend);
            var sector = try backend.allocator.alloc(u8, sector_size);
            defer backend.allocator.free(sector);

            var remaining = src;
            var cursor = offset;
            while (remaining.len > 0) {
                const sector_offset_u64 = cursor % backend.sector_size;
                const sector_offset: usize = @intCast(sector_offset_u64);
                const sector_start = cursor - sector_offset_u64;
                const copy_len = @min(remaining.len, sector_size - sector_offset);

                if (sector_offset == 0 and copy_len == sector_size) {
                    @memcpy(sector, remaining[0..copy_len]);
                } else {
                    try backend.disk.read(.{
                        .path = path,
                        .offset = sector_start,
                        .buffer = sector,
                    });
                    @memcpy(sector[sector_offset..][0..copy_len], remaining[0..copy_len]);
                }
                try backend.disk.write(.{
                    .path = path,
                    .offset = sector_start,
                    .bytes = sector,
                });

                remaining = remaining[copy_len..];
                cursor += copy_len;
            }
        }

        fn zeroDiskBytes(
            backend: *Backend,
            path: []const u8,
            offset: u64,
            len: u64,
        ) disk_module.DiskError!void {
            if (len == 0) return;
            const sector_size = try sectorSizeUsize(backend);
            var zeros = try backend.allocator.alloc(u8, sector_size);
            defer backend.allocator.free(zeros);
            @memset(zeros, 0);

            var remaining = len;
            var cursor = offset;
            while (remaining > 0) {
                const write_len: usize = @intCast(@min(remaining, @as(u64, @intCast(zeros.len))));
                try writeDiskBytes(backend, path, zeros[0..write_len], cursor);
                cursor += write_len;
                remaining -= write_len;
            }
        }

        fn sectorSizeUsize(backend: *const Backend) disk_module.DiskError!usize {
            if (backend.sector_size == 0) return error.InvalidAlignment;
            if (backend.sector_size > std.math.maxInt(usize)) return error.InvalidRange;
            return @intCast(backend.sector_size);
        }
    };
}
