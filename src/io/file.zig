//! `std.Io.File` and directory operations backed by Marionette disk.

const std = @import("std");

const disk_module = @import("../disk/root.zig");
const errors = @import("errors.zig");
const Io = std.Io;

pub fn Ops(comptime Backend: type) type {
    return struct {
        fn backendFromUserdata(userdata: ?*anyopaque) *Backend {
            return @ptrCast(@alignCast(userdata.?));
        }

        fn resolvePath(
            backend: *Backend,
            dir: Io.Dir,
            sub_path: []const u8,
            kind: disk_module.LogicalPathKind,
        ) ![]u8 {
            return backend.resolvePathAlloc(dir, sub_path, kind) catch |err| switch (err) {
                error.OutOfMemory => return error.SystemResources,
                error.InvalidDirHandle => return error.AccessDenied,
                error.InvalidPath => return error.FileNotFound,
            };
        }

        fn buildDirectoryStat(backend: *Backend, stat: disk_module.DiskStatDirResult) Io.File.Stat {
            return .{
                .inode = stat.inode,
                .nlink = 1,
                .size = 0,
                .permissions = .default_dir,
                .kind = .directory,
                .atime = .zero,
                .mtime = Io.Timestamp.fromNanoseconds(@intCast(stat.mtime_ns)),
                .ctime = .zero,
                .block_size = @intCast(@min(backend.sector_size, std.math.maxInt(Io.File.BlockSize))),
            };
        }

        fn cachedFileInodeForDirEntry(backend: *Backend, base: []const u8, name: []const u8) ?Io.File.INode {
            for (backend.files.items) |file_meta| {
                if (file_meta.deleted) continue;
                const child_name = if (std.mem.eql(u8, base, ".")) b: {
                    if (std.mem.indexOfScalar(u8, file_meta.path, '/') != null) continue;
                    break :b file_meta.path;
                } else b: {
                    if (!std.mem.startsWith(u8, file_meta.path, base)) continue;
                    if (file_meta.path.len <= base.len or file_meta.path[base.len] != '/') continue;
                    const relative = file_meta.path[base.len + 1 ..];
                    if (std.mem.indexOfScalar(u8, relative, '/') != null) continue;
                    break :b relative;
                };
                if (std.mem.eql(u8, child_name, name)) return file_meta.inode;
            }
            return null;
        }

        pub fn simDirCreateDir(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            _: Io.Dir.Permissions,
        ) Io.Dir.CreateDirError!void {
            const backend = backendFromUserdata(userdata);
            const path = resolvePath(backend, dir, sub_path, .directory) catch |err| return err;
            defer backend.allocator.free(path);
            backend.createDirectory(path) catch |err| return mapCreateDirError(err);
        }

        pub fn simDirCreateDirPath(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            _: Io.Dir.Permissions,
        ) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
            const backend = backendFromUserdata(userdata);
            const path = resolvePath(backend, dir, sub_path, .directory) catch |err| return err;
            defer backend.allocator.free(path);
            return backend.createDirectoryPath(path) catch |err| switch (err) {
                error.OutOfMemory => error.SystemResources,
                error.PathAlreadyExists => error.PathAlreadyExists,
                error.FileNotFound => error.FileNotFound,
                error.NotDir => error.NotDir,
                else => error.Unexpected,
            };
        }

        pub fn simDirCreateDirPathOpen(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            permissions: Io.Dir.Permissions,
            options: Io.Dir.OpenOptions,
        ) Io.Dir.CreateDirPathOpenError!Io.Dir {
            _ = try simDirCreateDirPath(userdata, dir, sub_path, permissions);
            return try simDirOpenDir(userdata, dir, sub_path, options);
        }

        pub fn simDirOpenDir(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            options: Io.Dir.OpenOptions,
        ) Io.Dir.OpenError!Io.Dir {
            _ = options.access_sub_paths;
            _ = options.follow_symlinks;
            const backend = backendFromUserdata(userdata);
            const path = resolvePath(backend, dir, sub_path, .directory) catch |err| return err;
            defer backend.allocator.free(path);
            return backend.openDirectoryHandle(path, options.iterate) catch |err| switch (err) {
                error.OutOfMemory => error.SystemResources,
                error.FileNotFound => error.FileNotFound,
                error.NotDir => error.NotDir,
                else => error.Unexpected,
            };
        }

        pub fn simDirCreateFile(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            options: Io.Dir.CreateFileOptions,
        ) Io.File.OpenError!Io.File {
            const backend = backendFromUserdata(userdata);
            const path = resolvePath(backend, dir, sub_path, .file) catch |err| return err;
            var path_owned = true;
            defer if (path_owned) backend.allocator.free(path);
            if (backend.directoryExists(path) catch |err| return mapDiskOpenError(err)) return error.IsDir;
            try requireParentDirectory(backend, path);
            const existing_index = findOrDiscoverFileMeta(backend, path) catch |err| {
                return errors.mapDiskOpenError(err);
            };
            const file_index = if (existing_index) |index| {
                if (options.exclusive) return error.PathAlreadyExists;
                backend.allocator.free(path);
                path_owned = false;
                const file = backend.openFileHandle(
                    index,
                    options.read,
                    true,
                    options.lock,
                    options.lock_nonblocking,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.SystemResources,
                    error.WouldBlock => return error.WouldBlock,
                };
                errdefer backend.retireFileHandle(file.handle);
                if (options.truncate) {
                    const old_len = backend.files.items[index].len;
                    backend.disk.setLength(.{
                        .path = backend.files.items[index].path,
                        .len = 0,
                    }) catch |err| switch (err) {
                        error.FileNotFound => {},
                        else => return errors.mapDiskOpenError(err),
                    };
                    backend.files.items[index].len = 0;
                    if (old_len != 0) backend.files.items[index].mtime = backend.nowTimestamp();
                }
                return file;
            } else b: {
                backend.disk.write(.{ .path = path, .offset = 0, .bytes = &.{} }) catch |err| {
                    return errors.mapDiskOpenError(err);
                };
                const index = backend.createFileMeta(path) catch return error.SystemResources;
                const stat_result = backend.disk.stat(.{ .path = path }) catch |err| {
                    backend.discardFileMeta(index);
                    return errors.mapDiskOpenError(err);
                };
                backend.files.items[index].len = stat_result.size;
                backend.files.items[index].inode = stat_result.inode;
                backend.allocator.free(path);
                path_owned = false;
                break :b index;
            };

            return backend.openFileHandle(
                file_index,
                options.read,
                true,
                options.lock,
                options.lock_nonblocking,
            ) catch |err| switch (err) {
                error.OutOfMemory => error.SystemResources,
                error.WouldBlock => error.WouldBlock,
            };
        }

        pub fn simDirOpenFile(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            options: Io.Dir.OpenFileOptions,
        ) Io.File.OpenError!Io.File {
            if (options.path_only) return error.AccessDenied;
            const backend = backendFromUserdata(userdata);
            const path = resolvePath(backend, dir, sub_path, .directory) catch |err| return err;
            var path_owned = true;
            defer if (path_owned) backend.allocator.free(path);
            if (backend.directoryExists(path) catch |err| return mapDiskOpenError(err)) {
                if (!options.allow_directory or options.isWrite()) return error.IsDir;
                return backend.openDirectoryFileHandle(path) catch return error.SystemResources;
            }
            const file_index = (findOrDiscoverFileMeta(backend, path) catch |err| {
                return errors.mapDiskOpenError(err);
            }) orelse return error.FileNotFound;
            backend.allocator.free(path);
            path_owned = false;
            return backend.openFileHandle(
                file_index,
                options.isRead(),
                options.isWrite(),
                options.lock,
                options.lock_nonblocking,
            ) catch |err| switch (err) {
                error.OutOfMemory => error.SystemResources,
                error.WouldBlock => error.WouldBlock,
            };
        }

        pub fn simDirClose(userdata: ?*anyopaque, dirs: []const Io.Dir) void {
            const backend = backendFromUserdata(userdata);
            for (dirs) |dir| backend.closeDirectoryHandle(dir);
        }

        pub fn simDirStat(
            userdata: ?*anyopaque,
            dir: Io.Dir,
        ) Io.Dir.StatError!Io.Dir.Stat {
            const backend = backendFromUserdata(userdata);
            const path = backend.directoryPath(dir) orelse return error.AccessDenied;
            const stat = backend.disk.statDir(.{ .path = path }) catch return error.AccessDenied;
            return buildDirectoryStat(backend, stat);
        }

        pub fn simDirStatFile(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            options: Io.Dir.StatFileOptions,
        ) Io.Dir.StatFileError!Io.File.Stat {
            _ = options.follow_symlinks;
            const backend = backendFromUserdata(userdata);
            const path = resolvePath(backend, dir, sub_path, .directory) catch |err| return err;
            defer backend.allocator.free(path);
            if (backend.disk.statDir(.{ .path = path })) |stat| {
                return buildDirectoryStat(backend, stat);
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return error.FileNotFound,
            }
            // Discovery failures other than not-found collapse to
            // FileNotFound here: StatFileError has no closer member for a
            // crashed or unavailable disk.
            const file_index = (findOrDiscoverFileMeta(backend, path) catch {
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
            if (options.execute) return error.AccessDenied;
            const backend = backendFromUserdata(userdata);
            const path = resolvePath(backend, dir, sub_path, .directory) catch |err| return err;
            defer backend.allocator.free(path);
            if (backend.directoryExists(path) catch return error.FileNotFound) return;
            _ = (findOrDiscoverFileMeta(backend, path) catch {
                return error.FileNotFound;
            }) orelse return error.FileNotFound;
        }

        pub fn simDirRead(
            userdata: ?*anyopaque,
            reader: *Io.Dir.Reader,
            entries: []Io.Dir.Entry,
        ) Io.Dir.Reader.Error!usize {
            const backend = backendFromUserdata(userdata);
            if (!backend.directoryHandleCanIterate(reader.dir)) return error.AccessDenied;
            const base = backend.directoryPath(reader.dir) orelse return error.AccessDenied;
            if (reader.state == .reset) {
                reader.index = 0;
                reader.state = .reading;
            }
            if (reader.state == .finished or entries.len == 0) return 0;

            var listing = backend.disk.readDir(.{
                .allocator = backend.allocator,
                .path = base,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.SystemResources,
                else => return error.AccessDenied,
            };
            defer listing.deinit();

            const candidate_count = listing.entries.len;
            var output_count: usize = 0;
            var name_offset: usize = 0;
            while (reader.index < candidate_count and output_count < entries.len) {
                const candidate = listing.entries[reader.index];
                reader.index += 1;
                const name = candidate.name;
                if (name.len > reader.buffer.len) return error.SystemResources;
                if (name_offset + name.len > reader.buffer.len) {
                    reader.index -= 1;
                    break;
                }
                @memcpy(reader.buffer[name_offset..][0..name.len], name);
                entries[output_count] = .{
                    .name = reader.buffer[name_offset..][0..name.len],
                    .kind = switch (candidate.kind) {
                        .file => .file,
                        .directory => .directory,
                    },
                    .inode = if (candidate.kind == .file)
                        cachedFileInodeForDirEntry(backend, base, name) orelse candidate.inode
                    else
                        candidate.inode,
                };
                name_offset += name.len;
                output_count += 1;
            }
            reader.end = name_offset;
            if (reader.index >= candidate_count) reader.state = .finished;
            return output_count;
        }

        pub fn simDirDeleteFile(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
        ) Io.Dir.DeleteFileError!void {
            const backend = backendFromUserdata(userdata);
            const path = resolvePath(backend, dir, sub_path, .file) catch |err| return err;
            defer backend.allocator.free(path);
            if (backend.directoryExists(path) catch return error.FileNotFound) return error.IsDir;
            _ = (findOrDiscoverFileMeta(backend, path) catch |err| {
                return errors.mapDiskDeleteError(err);
            }) orelse return error.FileNotFound;
            backend.disk.delete(.{ .path = path }) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return errors.mapDiskDeleteError(err),
            };

            backend.discardFileMetaForPathAcrossProcesses(path);
        }

        pub fn simDirRename(
            userdata: ?*anyopaque,
            old_dir: Io.Dir,
            old_sub_path: []const u8,
            new_dir: Io.Dir,
            new_sub_path: []const u8,
        ) Io.Dir.RenameError!void {
            const backend = backendFromUserdata(userdata);
            const old_path = resolvePath(backend, old_dir, old_sub_path, .file) catch |err| return err;
            defer backend.allocator.free(old_path);
            const new_path = resolvePath(backend, new_dir, new_sub_path, .file) catch |err| return err;
            defer backend.allocator.free(new_path);
            if (backend.directoryExists(old_path) catch return error.FileNotFound) return error.IsDir;
            if (backend.directoryExists(new_path) catch return error.FileNotFound) return error.IsDir;
            const new_parent = std.fs.path.dirname(new_path) orelse ".";
            if (!std.mem.eql(u8, new_parent, ".") and
                !(backend.directoryExists(new_parent) catch return error.FileNotFound))
            {
                return error.FileNotFound;
            }
            const old_index = (findOrDiscoverFileMeta(backend, old_path) catch |err| {
                return errors.mapDiskRenameError(err);
            }) orelse return error.FileNotFound;
            if (std.mem.eql(u8, old_path, new_path)) return;

            backend.reserveFileLockPath(new_path) catch |err| switch (err) {
                error.OutOfMemory => return error.SystemResources,
                error.WouldBlock => return error.FileBusy,
            };
            var destination_reserved = true;
            defer if (destination_reserved) backend.releaseFileLockPathReservation(new_path);
            var prepared_meta = backend.prepareFileMetaRename(old_path, new_path) catch {
                return error.SystemResources;
            };
            defer prepared_meta.deinit(backend.allocator);
            var prepared_locks = backend.prepareFileLockRekey(old_path, new_path) catch {
                return error.SystemResources;
            };
            defer prepared_locks.deinit(backend.allocator);

            backend.disk.rename(.{ .old_path = old_path, .new_path = new_path }) catch |err| switch (err) {
                error.FileNotFound => {
                    if (backend.files.items[old_index].len != 0) return error.FileNotFound;
                },
                else => return errors.mapDiskRenameError(err),
            };

            backend.commitFileMetaRename(new_path, &prepared_meta);
            backend.releaseFileLockPathReservation(new_path);
            destination_reserved = false;
            backend.commitFileLockRekey(old_path, &prepared_locks);
        }

        pub fn simFileStat(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.AccessDenied;
            if (state.closed) return error.AccessDenied;
            return switch (state.target) {
                .file => |file_index| if (backend.files.items[file_index].deleted)
                    error.AccessDenied
                else
                    buildFileStat(backend, file_index),
                .directory => |path| {
                    const stat = backend.disk.statDir(.{ .path = path }) catch return error.AccessDenied;
                    return buildDirectoryStat(backend, stat);
                },
            };
        }

        fn buildFileStat(backend: *Backend, file_index: usize) Io.File.Stat {
            const meta = &backend.files.items[file_index];
            return .{
                .inode = meta.inode,
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
            if (state.closed) return error.AccessDenied;
            return switch (state.target) {
                .file => |file_index| if (backend.files.items[file_index].deleted)
                    error.AccessDenied
                else
                    backend.files.items[file_index].len,
                .directory => error.AccessDenied,
            };
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
            if (state.closed or !state.read) return error.NotOpenForReading;
            if (Backend.fileDirectoryPath(state) != null) return error.IsDir;
            if (backend.fileMeta(state).deleted) return error.NotOpenForReading;

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
            if (state.closed or !state.write) return error.NotOpenForWriting;
            if (Backend.fileDirectoryPath(state) != null) return error.NotOpenForWriting;
            if (backend.fileMeta(state).deleted) return error.NotOpenForWriting;

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
            if (state.closed or !state.read) return error.NotOpenForReading;
            if (Backend.fileDirectoryPath(state) != null) return error.IsDir;
            if (backend.fileMeta(state).deleted) return error.NotOpenForReading;

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
            if (state.closed or !state.write) return error.NotOpenForWriting;
            if (Backend.fileDirectoryPath(state) != null) return error.NotOpenForWriting;
            if (backend.fileMeta(state).deleted) return error.NotOpenForWriting;

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
            if (state.closed) return error.AccessDenied;
            if (Backend.fileDirectoryPath(state) != null) return error.Unseekable;
            if (backend.fileMeta(state).deleted) return error.AccessDenied;

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
            if (state.closed) return error.AccessDenied;
            if (Backend.fileDirectoryPath(state) != null) return error.Unseekable;
            if (backend.fileMeta(state).deleted) return error.AccessDenied;
            state.cursor = absolute_offset;
        }

        pub fn simFileSync(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.AccessDenied;
            if (state.closed) return error.AccessDenied;
            if (Backend.fileDirectoryPath(state)) |path| {
                backend.disk.syncDir(.{ .path = path }) catch |err| return errors.mapDiskSyncError(err);
                return;
            }
            if (backend.fileMeta(state).deleted) return error.AccessDenied;
            backend.disk.sync(.{ .path = backend.fileMeta(state).path }) catch |err| return errors.mapDiskSyncError(err);
        }

        pub fn simFileSetLength(userdata: ?*anyopaque, file: Io.File, new_length: u64) Io.File.SetLengthError!void {
            const backend = backendFromUserdata(userdata);
            const state = backend.file(file.handle) orelse return error.AccessDenied;
            if (state.closed or !state.write) return error.AccessDenied;
            if (Backend.fileDirectoryPath(state) != null) return error.AccessDenied;
            if (backend.fileMeta(state).deleted) return error.AccessDenied;
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
                meta.inode = stat_result.inode;
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
                meta.inode = stat_result.inode;
                return index;
            }

            const stat_result = backend.disk.stat(.{ .path = path }) catch |err| switch (err) {
                error.FileNotFound, error.DiskUnavailable => return null,
                else => return err,
            };
            const index = try backend.createFileMeta(path);
            backend.files.items[index].len = stat_result.size;
            backend.files.items[index].inode = stat_result.inode;
            return index;
        }

        fn requireParentDirectory(backend: *Backend, path: []const u8) Io.File.OpenError!void {
            const parent = std.fs.path.dirname(path) orelse ".";
            if (std.mem.eql(u8, parent, ".")) return;
            if (!(backend.directoryExists(parent) catch |err| return mapDiskOpenError(err))) {
                return error.FileNotFound;
            }
        }

        fn mapCreateDirError(err: disk_module.DiskError) Io.Dir.CreateDirError {
            return switch (err) {
                error.OutOfMemory => error.SystemResources,
                error.PathAlreadyExists => error.PathAlreadyExists,
                error.FileNotFound => error.FileNotFound,
                error.NotDir => error.NotDir,
                else => error.Unexpected,
            };
        }

        fn mapDiskOpenError(err: disk_module.DiskError) Io.File.OpenError {
            return switch (err) {
                error.OutOfMemory => error.SystemResources,
                error.FileNotFound => error.FileNotFound,
                error.NotDir => error.NotDir,
                error.IsDir => error.IsDir,
                else => error.Unexpected,
            };
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
            const len_u64: u64 = @intCast(bytes.len);
            if (std.math.maxInt(u64) - cursor.* < len_u64) return error.InvalidRange;
            const logical_len = @max(meta.len, cursor.* + len_u64);
            try writeDiskBytes(backend, meta.path, bytes, cursor.*, logical_len);
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
            logical_len: u64,
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
                const sector_logical_len = @min(
                    logical_len,
                    cursor + @as(u64, @intCast(copy_len)),
                );
                try backend.disk.write(.{
                    .path = path,
                    .offset = sector_start,
                    .bytes = sector,
                    .logical_len = sector_logical_len,
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
            if (std.math.maxInt(u64) - offset < len) return error.InvalidRange;
            const logical_len = offset + len;
            while (remaining > 0) {
                const write_len: usize = @intCast(@min(remaining, @as(u64, @intCast(zeros.len))));
                try writeDiskBytes(
                    backend,
                    path,
                    zeros[0..write_len],
                    cursor,
                    logical_len,
                );
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
