//! Minimal deterministic `std.Io` backend for simulation worlds.
//!
//! This is the Phase 0 backend: deterministic clock and randomness, synchronous
//! `async`, a small in-memory TCP stream subset, a flat file subset over
//! `SimDisk`, and explicit failure for unsupported filesystem/process
//! operations.

const std = @import("std");

const disk_module = @import("disk.zig");
const World = @import("world.zig").World;

const Io = std.Io;
const SocketHandle = Io.net.Socket.Handle;

pub const FutexWaitResult = enum {
    woken,
    timed_out,
};

pub const FutexWaitSet = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        block: *const fn (ptr: *anyopaque, key: usize) void,
        block_until: *const fn (ptr: *anyopaque, key: usize, deadline_ns: ?u64) FutexWaitResult,
        wake: *const fn (ptr: *anyopaque, key: usize, max_count: usize) usize,
    };

    pub fn block(self: FutexWaitSet, key: usize) void {
        self.vtable.block(self.ptr, key);
    }

    pub fn blockUntil(self: FutexWaitSet, key: usize, deadline_ns: ?u64) FutexWaitResult {
        return self.vtable.block_until(self.ptr, key, deadline_ns);
    }

    pub fn wake(self: FutexWaitSet, key: usize, max_count: usize) usize {
        return self.vtable.wake(self.ptr, key, max_count);
    }
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    world: *World,
    disk: disk_module.Disk,
    sector_size: u64,
    futex_wait_set: ?FutexWaitSet = null,
    futex_keys: std.ArrayList(FutexKeyEntry) = .empty,
    next_futex_key: usize = 1,
    files: std.ArrayList(FileMeta) = .empty,
    handles: std.ArrayList(HandleEntry) = .empty,
    next_handle: SocketHandle = 1000,

    const HandleEntry = struct {
        handle: SocketHandle,
        state: State,

        const State = union(enum) {
            listener: *ListenerState,
            connection: *ConnectionState,
            file: *FileState,
        };
    };

    const FileMeta = struct {
        path: []u8,
        len: u64 = 0,
        mtime: Io.Timestamp = .zero,
        deleted: bool = false,

        fn deinit(self: *FileMeta, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            self.* = undefined;
        }
    };

    const FutexKeyEntry = struct {
        address: usize,
        key: usize,
    };

    const ListenerState = struct {
        address: Io.net.IpAddress,
        pending: std.ArrayList(SocketHandle) = .empty,
        closed: bool = false,
    };

    const ConnectionState = struct {
        address: Io.net.IpAddress,
        inbox: std.ArrayList(u8) = .empty,
        peer: ?SocketHandle = null,
        closed: bool = false,
    };

    const FileState = struct {
        file_index: usize,
        read: bool,
        write: bool,
        cursor: u64 = 0,
        closed: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, world: *World, disk: disk_module.Disk, sector_size: u64) Backend {
        return .{
            .allocator = allocator,
            .world = world,
            .disk = disk,
            .sector_size = sector_size,
        };
    }

    pub fn deinit(self: *Backend) void {
        for (self.handles.items) |entry| switch (entry.state) {
            .listener => |listener_state| {
                listener_state.pending.deinit(self.allocator);
                self.allocator.destroy(listener_state);
            },
            .connection => |connection_state| {
                connection_state.inbox.deinit(self.allocator);
                self.allocator.destroy(connection_state);
            },
            .file => |file_state| {
                self.allocator.destroy(file_state);
            },
        };
        self.handles.deinit(self.allocator);
        self.futex_keys.deinit(self.allocator);
        for (self.files.items) |*file_meta| file_meta.deinit(self.allocator);
        self.files.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn io(self: *Backend) Io {
        return .{
            .userdata = self,
            .vtable = &sim_vtable,
        };
    }

    pub fn attachFutexWaitSet(self: *Backend, wait_set: FutexWaitSet) void {
        self.futex_wait_set = wait_set;
    }

    fn futexKey(self: *Backend, ptr: *const u32) usize {
        const address = @intFromPtr(ptr);
        for (self.futex_keys.items) |entry| {
            if (entry.address == address) return entry.key;
        }

        const key = self.next_futex_key;
        self.next_futex_key += 1;
        self.futex_keys.append(self.allocator, .{
            .address = address,
            .key = key,
        }) catch @panic("failed to allocate sim futex key");
        return key;
    }

    fn createHandle(self: *Backend, state: HandleEntry.State) std.mem.Allocator.Error!SocketHandle {
        const handle = self.next_handle;
        self.next_handle += 1;
        try self.handles.append(self.allocator, .{
            .handle = handle,
            .state = state,
        });
        return handle;
    }

    fn findEntry(self: *Backend, handle: SocketHandle) ?*HandleEntry {
        for (self.handles.items) |*entry| {
            if (entry.handle == handle) return entry;
        }
        return null;
    }

    fn findOpenListener(self: *Backend, address: *const Io.net.IpAddress) ?*HandleEntry {
        for (self.handles.items) |*entry| switch (entry.state) {
            .listener => |listener_state| {
                if (!listener_state.closed and listener_state.address.eql(address)) return entry;
            },
            .connection => {},
            .file => {},
        };
        return null;
    }

    fn listener(self: *Backend, handle: SocketHandle) ?*ListenerState {
        return switch ((self.findEntry(handle) orelse return null).state) {
            .listener => |state| state,
            .connection, .file => null,
        };
    }

    fn connection(self: *Backend, handle: SocketHandle) ?*ConnectionState {
        return switch ((self.findEntry(handle) orelse return null).state) {
            .listener, .file => null,
            .connection => |state| state,
        };
    }

    fn file(self: *Backend, handle: Io.File.Handle) ?*FileState {
        return switch ((self.findEntry(@intCast(handle)) orelse return null).state) {
            .listener, .connection => null,
            .file => |state| state,
        };
    }

    fn fileMeta(self: *Backend, file_state: *const FileState) *FileMeta {
        return &self.files.items[file_state.file_index];
    }

    fn findFileMetaIndex(self: *Backend, path: []const u8) ?usize {
        for (self.files.items, 0..) |file_meta, index| {
            if (file_meta.deleted) continue;
            if (std.mem.eql(u8, file_meta.path, path)) return index;
        }
        return null;
    }

    fn createFileMeta(self: *Backend, path: []const u8) std.mem.Allocator.Error!usize {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        for (self.files.items, 0..) |*file_meta, index| {
            if (!file_meta.deleted) continue;
            self.allocator.free(file_meta.path);
            file_meta.* = .{ .path = owned_path };
            return index;
        }

        try self.files.append(self.allocator, .{ .path = owned_path });
        return self.files.items.len - 1;
    }

    fn nowTimestamp(self: *const Backend) Io.Timestamp {
        return Io.Timestamp.fromNanoseconds(@intCast(self.world.now()));
    }

    fn closeFileHandlesForIndex(self: *Backend, file_index: usize) void {
        for (self.handles.items) |*entry| switch (entry.state) {
            .file => |file_state| {
                if (file_state.file_index == file_index) file_state.closed = true;
            },
            .listener, .connection => {},
        };
    }

    fn openFileHandle(
        self: *Backend,
        file_index: usize,
        read: bool,
        write: bool,
    ) std.mem.Allocator.Error!Io.File {
        const file_state = try self.allocator.create(FileState);
        errdefer self.allocator.destroy(file_state);
        file_state.* = .{
            .file_index = file_index,
            .read = read,
            .write = write,
        };

        const handle = try self.createHandle(.{ .file = file_state });
        return .{
            .handle = @intCast(handle),
            .flags = .{ .nonblocking = false },
        };
    }
};

pub fn deinitBackendOpaque(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const backend: *Backend = @ptrCast(@alignCast(ptr));
    backend.deinit();
    allocator.destroy(backend);
}

const sim_vtable: Io.VTable = .{
    .crashHandler = Io.noCrashHandler,

    .async = Io.noAsync,
    .concurrent = Io.failingConcurrent,
    .await = Io.unreachableAwait,
    .cancel = Io.unreachableCancel,

    .groupAsync = Io.noGroupAsync,
    .groupConcurrent = Io.failingGroupConcurrent,
    .groupAwait = Io.unreachableGroupAwait,
    .groupCancel = Io.unreachableGroupCancel,

    .recancel = noRecancel,
    .swapCancelProtection = noSwapCancelProtection,
    .checkCancel = noCheckCancel,

    .futexWait = simFutexWait,
    .futexWaitUncancelable = simFutexWaitUncancelable,
    .futexWake = simFutexWake,

    .operate = simOperate,
    .batchAwaitAsync = Io.unreachableBatchAwaitAsync,
    .batchAwaitConcurrent = Io.unreachableBatchAwaitConcurrent,
    .batchCancel = Io.unreachableBatchCancel,

    .dirCreateDir = Io.failingDirCreateDir,
    .dirCreateDirPath = Io.failingDirCreateDirPath,
    .dirCreateDirPathOpen = Io.failingDirCreateDirPathOpen,
    .dirOpenDir = Io.failingDirOpenDir,
    .dirStat = Io.failingDirStat,
    .dirStatFile = simDirStatFile,
    .dirAccess = simDirAccess,
    .dirCreateFile = simDirCreateFile,
    .dirCreateFileAtomic = Io.failingDirCreateFileAtomic,
    .dirOpenFile = simDirOpenFile,
    .dirClose = simDirClose,
    .dirRead = Io.noDirRead,
    .dirRealPath = Io.failingDirRealPath,
    .dirRealPathFile = Io.failingDirRealPathFile,
    .dirDeleteFile = simDirDeleteFile,
    .dirDeleteDir = Io.failingDirDeleteDir,
    .dirRename = simDirRename,
    .dirRenamePreserve = Io.failingDirRenamePreserve,
    .dirSymLink = Io.failingDirSymLink,
    .dirReadLink = Io.failingDirReadLink,
    .dirSetOwner = Io.failingDirSetOwner,
    .dirSetFileOwner = Io.failingDirSetFileOwner,
    .dirSetPermissions = Io.failingDirSetPermissions,
    .dirSetFilePermissions = Io.failingDirSetFilePermissions,
    .dirSetTimestamps = Io.noDirSetTimestamps,
    .dirHardLink = Io.failingDirHardLink,

    .fileStat = simFileStat,
    .fileLength = simFileLength,
    .fileClose = simFileClose,
    .fileWritePositional = simFileWritePositional,
    .fileWriteFileStreaming = Io.noFileWriteFileStreaming,
    .fileWriteFilePositional = Io.noFileWriteFilePositional,
    .fileReadPositional = simFileReadPositional,
    .fileSeekBy = simFileSeekBy,
    .fileSeekTo = simFileSeekTo,
    .fileSync = simFileSync,
    .fileIsTty = Io.unreachableFileIsTty,
    .fileEnableAnsiEscapeCodes = Io.unreachableFileEnableAnsiEscapeCodes,
    .fileSupportsAnsiEscapeCodes = Io.unreachableFileSupportsAnsiEscapeCodes,
    .fileSetLength = simFileSetLength,
    .fileSetOwner = Io.failingFileSetOwner,
    .fileSetPermissions = Io.failingFileSetPermissions,
    .fileSetTimestamps = Io.noFileSetTimestamps,
    .fileLock = Io.failingFileLock,
    .fileTryLock = Io.failingFileTryLock,
    .fileUnlock = Io.unreachableFileUnlock,
    .fileDowngradeLock = Io.failingFileDowngradeLock,
    .fileRealPath = Io.failingFileRealPath,
    .fileHardLink = Io.failingFileHardLink,

    .fileMemoryMapCreate = Io.failingFileMemoryMapCreate,
    .fileMemoryMapDestroy = Io.unreachableFileMemoryMapDestroy,
    .fileMemoryMapSetLength = Io.unreachableFileMemoryMapSetLength,
    .fileMemoryMapRead = Io.unreachableFileMemoryMapRead,
    .fileMemoryMapWrite = Io.unreachableFileMemoryMapWrite,

    .processExecutableOpen = Io.failingProcessExecutableOpen,
    .processExecutablePath = Io.failingProcessExecutablePath,
    .lockStderr = Io.unreachableLockStderr,
    .tryLockStderr = Io.noTryLockStderr,
    .unlockStderr = Io.unreachableUnlockStderr,
    .processCurrentPath = Io.failingProcessCurrentPath,
    .processSetCurrentDir = Io.failingProcessSetCurrentDir,
    .processSetCurrentPath = Io.failingProcessSetCurrentPath,
    .processReplace = Io.failingProcessReplace,
    .processReplacePath = Io.failingProcessReplacePath,
    .processSpawn = Io.failingProcessSpawn,
    .processSpawnPath = Io.failingProcessSpawnPath,
    .childWait = Io.unreachableChildWait,
    .childKill = Io.unreachableChildKill,

    .progressParentFile = Io.failingProgressParentFile,

    .random = simRandom,
    .randomSecure = simRandomSecure,

    .now = simNow,
    .clockResolution = simClockResolution,
    .sleep = simSleep,

    .netListenIp = simNetListenIp,
    .netAccept = simNetAccept,
    .netBindIp = Io.failingNetBindIp,
    .netConnectIp = simNetConnectIp,
    .netListenUnix = Io.failingNetListenUnix,
    .netConnectUnix = Io.failingNetConnectUnix,
    .netSocketCreatePair = Io.failingNetSocketCreatePair,
    .netSend = Io.failingNetSend,
    .netRead = simNetRead,
    .netWrite = simNetWrite,
    .netWriteFile = Io.failingNetWriteFile,
    .netClose = simNetClose,
    .netShutdown = simNetShutdown,
    .netInterfaceNameResolve = Io.failingNetInterfaceNameResolve,
    .netInterfaceName = Io.unreachableNetInterfaceName,
    .netLookup = Io.failingNetLookup,
};

fn backendFromUserdata(userdata: ?*anyopaque) *Backend {
    return @ptrCast(@alignCast(userdata.?));
}

fn worldFromUserdata(userdata: ?*anyopaque) *World {
    return backendFromUserdata(userdata).world;
}

fn supportsClock(clock: Io.Clock) bool {
    return switch (clock) {
        .real, .awake, .boot => true,
        .cpu_process, .cpu_thread => false,
    };
}

fn simRandom(userdata: ?*anyopaque, buffer: []u8) void {
    worldFromUserdata(userdata).unsafeUntracedRandom().bytes(buffer);
}

fn simRandomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    simRandom(userdata, buffer);
}

fn noRecancel(userdata: ?*anyopaque) void {
    _ = userdata;
}

fn noSwapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    _ = userdata;
    _ = new;
    return .unblocked;
}

fn noCheckCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    _ = userdata;
}

fn simFutexWait(
    userdata: ?*anyopaque,
    ptr: *const u32,
    expected: u32,
    timeout: Io.Timeout,
) Io.Cancelable!void {
    const backend = backendFromUserdata(userdata);
    if (@atomicLoad(u32, ptr, .monotonic) != expected) return;
    const deadline_ns = simFutexDeadline(backend, timeout);
    if (deadline_ns != null and deadline_ns.? <= backend.world.now()) return;

    // Cooperative atomicity: no task can run between this value check and the
    // park unless this function yields. Keep the check adjacent to `block` so
    // futex's check-and-sleep race stays closed in simulation.
    const wait_set = backend.futex_wait_set orelse @panic("sim futex wait requires an attached scheduler");
    switch (wait_set.blockUntil(backend.futexKey(ptr), deadline_ns)) {
        .woken => {},
        .timed_out => {},
    }
}

fn simFutexDeadline(backend: *Backend, timeout: Io.Timeout) ?u64 {
    return switch (timeout) {
        .none => null,
        .duration => |duration| {
            if (!supportsClock(duration.clock)) return null;
            if (duration.raw.nanoseconds <= 0) return backend.world.now();

            const now = backend.world.now();
            const delta: u64 = std.math.cast(u64, duration.raw.nanoseconds) orelse return null;
            if (std.math.maxInt(u64) - now < delta) return null;
            return now + delta;
        },
        .deadline => |deadline| {
            if (!supportsClock(deadline.clock)) return null;
            return std.math.cast(u64, deadline.raw.nanoseconds) orelse backend.world.now();
        },
    };
}

fn simFutexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    simFutexWait(userdata, ptr, expected, .none) catch |err| switch (err) {
        error.Canceled => unreachable,
    };
}

fn simFutexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    if (max_waiters == 0) return;
    const backend = backendFromUserdata(userdata);
    const wait_set = backend.futex_wait_set orelse return;
    _ = wait_set.wake(backend.futexKey(ptr), max_waiters);
}

fn simOperate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    return switch (operation) {
        .file_read_streaming => |read| .{
            .file_read_streaming = simFileReadStreaming(userdata, read.file, read.data),
        },
        .file_write_streaming => |write| .{
            .file_write_streaming = simFileWriteStreaming(userdata, write.file, write.header, write.data, write.splat),
        },
        .device_io_control => unreachable,
        .net_receive => .{ .net_receive = .{ error.NetworkDown, 0 } },
    };
}

fn simNow(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    if (!supportsClock(clock)) return .zero;
    return .fromNanoseconds(@intCast(worldFromUserdata(userdata).now()));
}

fn simClockResolution(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    if (!supportsClock(clock)) return error.ClockUnavailable;
    const world = worldFromUserdata(userdata);
    return .fromNanoseconds(@intCast(world.clock().tick_ns));
}

fn simSleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const world = worldFromUserdata(userdata);
    const duration = switch (timeout) {
        .none => return,
        .duration => |duration| b: {
            if (!supportsClock(duration.clock)) return;
            break :b duration.raw;
        },
        .deadline => |deadline| b: {
            if (!supportsClock(deadline.clock)) return;
            const now = world.now();
            if (deadline.raw.nanoseconds <= now) return;
            break :b Io.Duration.fromNanoseconds(deadline.raw.nanoseconds - now);
        },
    };
    if (duration.nanoseconds <= 0) return;
    world.clock().runFor(@intCast(duration.nanoseconds));
}

fn simDirCreateFile(
    userdata: ?*anyopaque,
    dir: Io.Dir,
    sub_path: []const u8,
    options: Io.Dir.CreateFileOptions,
) Io.File.OpenError!Io.File {
    _ = dir;
    if (options.lock != .none) return error.FileLocksUnsupported;
    if (!isValidSimPath(sub_path)) return error.FileNotFound;

    const backend = backendFromUserdata(userdata);
    const file_index = if (backend.findFileMetaIndex(sub_path)) |index| b: {
        if (options.exclusive) return error.PathAlreadyExists;
        if (options.truncate) {
            const old_len = backend.files.items[index].len;
            backend.disk.setLength(.{ .path = sub_path, .len = 0 }) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return mapDiskOpenError(err),
            };
            backend.files.items[index].len = 0;
            if (old_len != 0) backend.files.items[index].mtime = backend.nowTimestamp();
        }
        break :b index;
    } else b: {
        backend.disk.write(.{ .path = sub_path, .offset = 0, .bytes = &.{} }) catch |err| {
            return mapDiskOpenError(err);
        };
        break :b backend.createFileMeta(sub_path) catch return error.SystemResources;
    };

    return backend.openFileHandle(file_index, options.read, true) catch return error.SystemResources;
}

fn simDirOpenFile(
    userdata: ?*anyopaque,
    dir: Io.Dir,
    sub_path: []const u8,
    options: Io.Dir.OpenFileOptions,
) Io.File.OpenError!Io.File {
    _ = dir;
    _ = options.allow_directory;
    if (options.path_only) return error.AccessDenied;
    if (options.lock != .none) return error.FileLocksUnsupported;
    if (!isValidSimPath(sub_path)) return error.FileNotFound;

    const backend = backendFromUserdata(userdata);
    const file_index = backend.findFileMetaIndex(sub_path) orelse return error.FileNotFound;
    return backend.openFileHandle(file_index, options.isRead(), options.isWrite()) catch return error.SystemResources;
}

fn simDirClose(userdata: ?*anyopaque, dirs: []const Io.Dir) void {
    _ = userdata;
    _ = dirs;
}

fn simDirStatFile(
    userdata: ?*anyopaque,
    dir: Io.Dir,
    sub_path: []const u8,
    options: Io.Dir.StatFileOptions,
) Io.Dir.StatFileError!Io.File.Stat {
    _ = dir;
    _ = options.follow_symlinks;
    if (!isValidSimPath(sub_path)) return error.FileNotFound;

    const backend = backendFromUserdata(userdata);
    const file_index = backend.findFileMetaIndex(sub_path) orelse return error.FileNotFound;
    return buildFileStat(backend, file_index);
}

fn simDirAccess(
    userdata: ?*anyopaque,
    dir: Io.Dir,
    sub_path: []const u8,
    options: Io.Dir.AccessOptions,
) Io.Dir.AccessError!void {
    _ = dir;
    if (options.execute) return error.AccessDenied;
    if (!isValidSimPath(sub_path)) return error.FileNotFound;

    const backend = backendFromUserdata(userdata);
    _ = backend.findFileMetaIndex(sub_path) orelse return error.FileNotFound;
}

fn simDirDeleteFile(
    userdata: ?*anyopaque,
    dir: Io.Dir,
    sub_path: []const u8,
) Io.Dir.DeleteFileError!void {
    _ = dir;
    if (!isValidSimPath(sub_path)) return error.FileNotFound;

    const backend = backendFromUserdata(userdata);
    const file_index = backend.findFileMetaIndex(sub_path) orelse return error.FileNotFound;
    backend.disk.delete(.{ .path = sub_path }) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return mapDiskDeleteError(err),
    };

    backend.closeFileHandlesForIndex(file_index);
    backend.files.items[file_index].deleted = true;
    backend.files.items[file_index].len = 0;
}

fn simDirRename(
    userdata: ?*anyopaque,
    old_dir: Io.Dir,
    old_sub_path: []const u8,
    new_dir: Io.Dir,
    new_sub_path: []const u8,
) Io.Dir.RenameError!void {
    _ = old_dir;
    _ = new_dir;
    if (!isValidSimPath(old_sub_path)) return error.FileNotFound;
    if (!isValidSimPath(new_sub_path)) return error.FileNotFound;

    const backend = backendFromUserdata(userdata);
    const old_index = backend.findFileMetaIndex(old_sub_path) orelse return error.FileNotFound;
    if (std.mem.eql(u8, old_sub_path, new_sub_path)) return;

    const new_index = backend.findFileMetaIndex(new_sub_path);
    const owned_path = backend.allocator.dupe(u8, new_sub_path) catch return error.SystemResources;
    errdefer backend.allocator.free(owned_path);

    backend.disk.rename(.{ .old_path = old_sub_path, .new_path = new_sub_path }) catch |err| switch (err) {
        error.FileNotFound => {
            if (backend.files.items[old_index].len != 0) return error.FileNotFound;
        },
        else => return mapDiskRenameError(err),
    };

    if (new_index) |index| {
        backend.closeFileHandlesForIndex(index);
        backend.files.items[index].deleted = true;
        backend.files.items[index].len = 0;
    }

    backend.allocator.free(backend.files.items[old_index].path);
    backend.files.items[old_index].path = owned_path;
}

fn simFileStat(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
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

fn simFileLength(userdata: ?*anyopaque, file: Io.File) Io.File.LengthError!u64 {
    const backend = backendFromUserdata(userdata);
    const state = backend.file(file.handle) orelse return error.AccessDenied;
    if (state.closed or backend.fileMeta(state).deleted) return error.AccessDenied;
    return backend.fileMeta(state).len;
}

fn simFileClose(userdata: ?*anyopaque, files: []const Io.File) void {
    const backend = backendFromUserdata(userdata);
    for (files) |file| {
        if (backend.file(file.handle)) |state| state.closed = true;
    }
}

fn simFileReadPositional(
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
        readDiskBytes(backend, meta.path, buffer[0..read_len], cursor) catch |err| return mapDiskReadError(err);
        cursor += read_len;
        total += read_len;
        if (read_len < buffer.len) break;
    }
    return total;
}

fn simFileWritePositional(
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

    writePart(backend, meta, header, &cursor, &total) catch |err| return mapDiskWriteError(err);
    if (data.len > 0) {
        for (data[0 .. data.len - 1]) |bytes| {
            writePart(backend, meta, bytes, &cursor, &total) catch |err| return mapDiskWriteError(err);
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            writePart(backend, meta, pattern, &cursor, &total) catch |err| return mapDiskWriteError(err);
        }
    }
    if (total != 0) meta.mtime = backend.nowTimestamp();
    return total;
}

fn simFileReadStreaming(
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

fn simFileWriteStreaming(
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

fn simFileSeekBy(userdata: ?*anyopaque, file: Io.File, relative_offset: i64) Io.File.SeekError!void {
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

fn simFileSeekTo(userdata: ?*anyopaque, file: Io.File, absolute_offset: u64) Io.File.SeekError!void {
    const backend = backendFromUserdata(userdata);
    const state = backend.file(file.handle) orelse return error.AccessDenied;
    if (state.closed or backend.fileMeta(state).deleted) return error.AccessDenied;
    state.cursor = absolute_offset;
}

fn simFileSync(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
    const backend = backendFromUserdata(userdata);
    const state = backend.file(file.handle) orelse return error.AccessDenied;
    if (state.closed or backend.fileMeta(state).deleted) return error.AccessDenied;
    backend.disk.sync(.{ .path = backend.fileMeta(state).path }) catch |err| return mapDiskSyncError(err);
}

fn simFileSetLength(userdata: ?*anyopaque, file: Io.File, new_length: u64) Io.File.SetLengthError!void {
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
        else => return mapDiskSetLengthError(err),
    };
    meta.len = new_length;
    if (new_length != old_len) meta.mtime = backend.nowTimestamp();
}

fn isValidSimPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (std.fs.path.isAbsolute(path)) return false;

    var parts = std.mem.splitAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
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

fn mapDiskReadError(err: disk_module.DiskError) Io.File.ReadPositionalError {
    return switch (err) {
        error.OutOfMemory => error.SystemResources,
        else => error.InputOutput,
    };
}

fn mapDiskWriteError(err: disk_module.DiskError) Io.File.WritePositionalError {
    return switch (err) {
        error.OutOfMemory => error.SystemResources,
        else => error.InputOutput,
    };
}

fn mapDiskSyncError(err: disk_module.DiskError) Io.File.SyncError {
    return switch (err) {
        error.DiskUnavailable,
        error.FileNotFound,
        error.DiskCrashed,
        error.WriteError,
        error.ReadError,
        error.InvalidAlignment,
        error.InvalidDuration,
        error.InvalidPath,
        error.InvalidRate,
        error.InvalidRange,
        error.OutOfMemory,
        error.InvalidTracePayload,
        => error.InputOutput,
    };
}

fn mapDiskOpenError(err: disk_module.DiskError) Io.File.OpenError {
    return switch (err) {
        error.OutOfMemory => error.SystemResources,
        error.FileNotFound => error.FileNotFound,
        error.InvalidPath,
        error.InvalidAlignment,
        error.InvalidRange,
        => error.FileNotFound,
        else => error.SystemResources,
    };
}

fn mapDiskSetLengthError(err: disk_module.DiskError) Io.File.SetLengthError {
    return switch (err) {
        error.OutOfMemory => error.InputOutput,
        error.FileNotFound => error.AccessDenied,
        error.InvalidPath,
        error.InvalidAlignment,
        error.InvalidRange,
        => error.AccessDenied,
        else => error.InputOutput,
    };
}

fn mapDiskDeleteError(err: disk_module.DiskError) Io.Dir.DeleteFileError {
    return switch (err) {
        error.OutOfMemory => error.SystemResources,
        error.FileNotFound => error.FileNotFound,
        error.InvalidPath,
        error.InvalidAlignment,
        error.InvalidRange,
        => error.FileNotFound,
        else => error.FileSystem,
    };
}

fn mapDiskRenameError(err: disk_module.DiskError) Io.Dir.RenameError {
    return switch (err) {
        error.OutOfMemory => error.SystemResources,
        error.FileNotFound => error.FileNotFound,
        error.InvalidPath,
        error.InvalidAlignment,
        error.InvalidRange,
        => error.FileNotFound,
        else => error.HardwareFailure,
    };
}

fn simNetListenIp(
    userdata: ?*anyopaque,
    address: *const Io.net.IpAddress,
    options: Io.net.IpAddress.ListenOptions,
) Io.net.IpAddress.ListenError!Io.net.Socket {
    if (options.mode != .stream) return error.SocketModeUnsupported;
    if (options.protocol != .tcp) return error.ProtocolUnsupportedBySystem;

    const backend = backendFromUserdata(userdata);
    if (backend.findOpenListener(address) != null) return error.AddressInUse;

    const listener = backend.allocator.create(Backend.ListenerState) catch return error.SystemResources;
    errdefer backend.allocator.destroy(listener);
    listener.* = .{ .address = address.* };
    errdefer listener.pending.deinit(backend.allocator);

    const handle = backend.createHandle(.{ .listener = listener }) catch return error.SystemResources;
    return .{
        .handle = handle,
        .address = address.*,
    };
}

fn simNetConnectIp(
    userdata: ?*anyopaque,
    address: *const Io.net.IpAddress,
    options: Io.net.IpAddress.ConnectOptions,
) Io.net.IpAddress.ConnectError!Io.net.Socket {
    if (options.mode != .stream) return error.SocketModeUnsupported;
    if (options.protocol) |protocol| {
        if (protocol != .tcp) return error.ProtocolUnsupportedBySystem;
    }

    const backend = backendFromUserdata(userdata);
    const listener_entry = backend.findOpenListener(address) orelse return error.ConnectionRefused;
    const listener = listener_entry.state.listener;

    const client = backend.allocator.create(Backend.ConnectionState) catch return error.SystemResources;
    errdefer backend.allocator.destroy(client);
    client.* = .{ .address = address.* };
    errdefer client.inbox.deinit(backend.allocator);

    const server = backend.allocator.create(Backend.ConnectionState) catch return error.SystemResources;
    errdefer backend.allocator.destroy(server);
    server.* = .{ .address = listener.address };
    errdefer server.inbox.deinit(backend.allocator);

    const client_handle = backend.createHandle(.{ .connection = client }) catch return error.SystemResources;
    errdefer _ = backend.handles.pop();
    const server_handle = backend.createHandle(.{ .connection = server }) catch return error.SystemResources;
    errdefer _ = backend.handles.pop();

    client.peer = server_handle;
    server.peer = client_handle;

    listener.pending.append(backend.allocator, server_handle) catch return error.SystemResources;
    return .{
        .handle = client_handle,
        .address = address.*,
    };
}

fn simNetAccept(
    userdata: ?*anyopaque,
    server: SocketHandle,
    options: Io.net.Server.AcceptOptions,
) Io.net.Server.AcceptError!Io.net.Socket {
    _ = options;

    const backend = backendFromUserdata(userdata);
    const state = backend.listener(server) orelse return error.SocketNotListening;
    if (state.closed) return error.SocketNotListening;
    if (state.pending.items.len == 0) return error.WouldBlock;

    const handle = state.pending.orderedRemove(0);
    return .{
        .handle = handle,
        .address = state.address,
    };
}

fn simNetRead(userdata: ?*anyopaque, src: SocketHandle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
    const backend = backendFromUserdata(userdata);
    const connection = backend.connection(src) orelse return error.SocketUnconnected;
    if (connection.closed) return error.SocketUnconnected;
    if (connection.inbox.items.len == 0) {
        const peer_closed = if (connection.peer) |peer_handle|
            if (backend.connection(peer_handle)) |peer| peer.closed else true
        else
            true;
        if (peer_closed) return 0;
        // FIXME(roadmap item 18): `Io.net.Stream.Reader.Error` has no WouldBlock
        // variant in Zig 0.16. Until Marionette has a scheduler that can park
        // this task, Timeout is the least-wrong way to report "peer open, no
        // bytes available yet."
        return error.Timeout;
    }

    var total_read: usize = 0;
    for (data) |buffer| {
        if (buffer.len == 0) continue;
        const read_count = @min(buffer.len, connection.inbox.items.len - total_read);
        @memcpy(buffer[0..read_count], connection.inbox.items[total_read..][0..read_count]);
        total_read += read_count;
        if (total_read == connection.inbox.items.len) break;
    }

    connection.inbox.replaceRangeAssumeCapacity(0, total_read, &.{});
    return total_read;
}

fn simNetWrite(
    userdata: ?*anyopaque,
    dest: SocketHandle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) Io.net.Stream.Writer.Error!usize {
    const backend = backendFromUserdata(userdata);
    const connection = backend.connection(dest) orelse return error.SocketUnconnected;
    if (connection.closed) return error.SocketUnconnected;
    const peer_handle = connection.peer orelse return error.SocketUnconnected;
    const peer = backend.connection(peer_handle) orelse return error.ConnectionResetByPeer;
    if (peer.closed) return error.ConnectionResetByPeer;

    const start_len = peer.inbox.items.len;
    errdefer peer.inbox.shrinkRetainingCapacity(start_len);

    peer.inbox.appendSlice(backend.allocator, header) catch return error.SystemResources;
    if (data.len > 0) {
        for (data[0 .. data.len - 1]) |bytes| {
            peer.inbox.appendSlice(backend.allocator, bytes) catch return error.SystemResources;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            peer.inbox.appendSlice(backend.allocator, pattern) catch return error.SystemResources;
        }
    }
    return peer.inbox.items.len - start_len;
}

fn simNetClose(userdata: ?*anyopaque, handles: []const SocketHandle) void {
    const backend = backendFromUserdata(userdata);
    for (handles) |handle| {
        const entry = backend.findEntry(handle) orelse continue;
        switch (entry.state) {
            .listener => |listener| listener.closed = true,
            .connection => |connection| connection.closed = true,
            .file => |file| file.closed = true,
        }
    }
}

fn simNetShutdown(userdata: ?*anyopaque, handle: SocketHandle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
    _ = how;
    simNetClose(userdata, (&handle)[0..1]);
}

fn testIo(world: *World) Backend {
    return .init(std.testing.allocator, world, disk_module.Disk.unavailable(), 4096);
}

test "io: simulation clock and sleep use world time" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 5 });
    defer world.deinit();

    var backend = testIo(&world);
    defer backend.deinit();
    const io = backend.io();
    try std.testing.expectEqual(@as(i96, 0), Io.Clock.awake.now(io).nanoseconds);
    try std.testing.expectEqual(@as(i96, 5), (try Io.Clock.awake.resolution(io)).nanoseconds);

    try Io.sleep(io, .fromNanoseconds(10), .awake);
    try std.testing.expectEqual(@as(i96, 10), Io.Clock.awake.now(io).nanoseconds);
}

test "io: simulation random is deterministic" {
    var a = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer a.deinit();
    var b = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer b.deinit();

    var a_bytes: [16]u8 = undefined;
    var b_bytes: [16]u8 = undefined;

    var a_backend = testIo(&a);
    defer a_backend.deinit();
    var b_backend = testIo(&b);
    defer b_backend.deinit();

    Io.random(a_backend.io(), &a_bytes);
    Io.random(b_backend.io(), &b_bytes);

    try std.testing.expectEqualSlices(u8, &a_bytes, &b_bytes);
}

test "io: simulation randomSecure is deterministic" {
    var a = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer a.deinit();
    var b = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer b.deinit();

    var a_bytes: [16]u8 = undefined;
    var b_bytes: [16]u8 = undefined;

    var a_backend = testIo(&a);
    defer a_backend.deinit();
    var b_backend = testIo(&b);
    defer b_backend.deinit();

    try Io.randomSecure(a_backend.io(), &a_bytes);
    try Io.randomSecure(b_backend.io(), &b_bytes);

    try std.testing.expectEqualSlices(u8, &a_bytes, &b_bytes);
}

test "io: simulation async completes synchronously" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const Helper = struct {
        fn addOne(value: u32) u32 {
            return value + 1;
        }
    };

    var backend = testIo(&world);
    defer backend.deinit();
    const io = backend.io();
    var future = Io.async(io, Helper.addOne, .{41});
    try std.testing.expectEqual(@as(u32, 42), future.await(io));
    try std.testing.expectError(error.ConcurrencyUnavailable, Io.concurrent(io, Helper.addOne, .{41}));
}

test "io: simulation cancellation checks are inert before fibers" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var backend = testIo(&world);
    defer backend.deinit();
    const io = backend.io();
    try Io.checkCancel(io);
    try std.testing.expectEqual(Io.CancelProtection.unblocked, Io.swapCancelProtection(io, .blocked));
    Io.recancel(io);
}

test "io: simulation futex wait returns immediately when value changed" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var backend = testIo(&world);
    defer backend.deinit();
    const io = backend.io();

    var value: u32 = 1;
    try io.futexWait(u32, &value, 0);
    io.futexWaitUncancelable(u32, &value, 0);
    io.futexWake(u32, &value, 1);
}

test "io: simulation queue works for immediately ready operations" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var backend = testIo(&world);
    defer backend.deinit();
    const io = backend.io();
    var backing: [4]u8 = undefined;
    var queue = Io.Queue(u8).init(&backing);

    try queue.putAll(io, &.{ 1, 2 });

    var out: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try queue.get(io, &out, 2));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &out);

    queue.close(io);
    try std.testing.expectError(error.Closed, queue.putOne(io, 3));
}

test "io: simulation files use byte semantics over SimDisk" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();

    var file = try Io.Dir.cwd().createFile(io, "data.bin", .{ .read = true });
    defer file.close(io);

    try file.writePositionalAll(io, "abcdef", 1);
    try std.testing.expectEqual(@as(u64, 7), try file.length(io));

    var buffer: [8]u8 = undefined;
    const read_len = try file.readPositionalAll(io, &buffer, 0);
    try std.testing.expectEqual(@as(usize, 7), read_len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 'a', 'b', 'c', 'd', 'e', 'f' }, buffer[0..read_len]);

    try file.sync(io);
}

test "io: simulation files support std.Io file readers and writers" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();

    var file = try Io.Dir.cwd().createFile(io, "stream.bin", .{ .read = true });
    defer file.close(io);

    try file.writePositionalAll(io, "abcdefgh", 0);

    var empty_reader_buffer: [0]u8 = .{};
    var reader = file.reader(io, &empty_reader_buffer);
    try reader.seekTo(4);

    var read_out: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try reader.interface.readSliceShort(&read_out));
    try std.testing.expectEqualStrings("ef", &read_out);

    var streaming_reader_buffer: [0]u8 = .{};
    var streaming_reader = file.readerStreaming(io, &streaming_reader_buffer);
    try streaming_reader.seekTo(2);
    try std.testing.expectEqual(@as(usize, 2), try streaming_reader.interface.readSliceShort(&read_out));
    try std.testing.expectEqualStrings("cd", &read_out);

    var streaming_writer_buffer: [0]u8 = .{};
    var streaming_writer = file.writerStreaming(io, &streaming_writer_buffer);
    try streaming_writer.seekTo(6);
    try streaming_writer.interface.writeAll("XY");
    try streaming_writer.flush();

    var final: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try file.readPositionalAll(io, &final, 0));
    try std.testing.expectEqualStrings("abcdefXY", &final);
}

test "io: simulation streaming cursors are per open file handle" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();

    var first = try Io.Dir.cwd().createFile(io, "handles.bin", .{ .read = true });
    defer first.close(io);
    try first.writePositionalAll(io, "abcdefgh", 0);

    var second = try Io.Dir.cwd().openFile(io, "handles.bin", .{ .mode = .read_only });
    defer second.close(io);

    var first_reader_buffer: [0]u8 = .{};
    var first_reader = first.readerStreaming(io, &first_reader_buffer);
    try first_reader.seekTo(4);

    var second_reader_buffer: [0]u8 = .{};
    var second_reader = second.readerStreaming(io, &second_reader_buffer);

    var read_out: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try second_reader.interface.readSliceShort(&read_out));
    try std.testing.expectEqualStrings("ab", &read_out);

    try std.testing.expectEqual(@as(usize, 2), try first_reader.interface.readSliceShort(&read_out));
    try std.testing.expectEqualStrings("ef", &read_out);
}

test "io: simulation streaming reads advance only by bytes read" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();

    var file = try Io.Dir.cwd().createFile(io, "eof.bin", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "abcdefgh", 0);

    var reader_buffer: [0]u8 = .{};
    var reader = file.readerStreaming(io, &reader_buffer);
    try reader.seekTo(6);

    var read_out: [4]u8 = @splat(0);
    try std.testing.expectEqual(@as(usize, 2), try reader.interface.readSliceShort(&read_out));
    try std.testing.expectEqualStrings("gh", read_out[0..2]);
    try std.testing.expectEqual(@as(u64, 8), reader.logicalPos());

    try std.testing.expectEqual(@as(usize, 0), try reader.interface.readSliceShort(&read_out));
    try std.testing.expectEqual(@as(u64, 8), reader.logicalPos());

    var writer_buffer: [0]u8 = .{};
    var writer = file.writerStreaming(io, &writer_buffer);
    try writer.seekTo(reader.logicalPos());
    try writer.interface.writeAll("XY");
    try writer.flush();

    var final: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 10), try file.readPositionalAll(io, &final, 0));
    try std.testing.expectEqualStrings("abcdefghXY", &final);
}

test "io: simulation streaming seek rejects negative underflow" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();

    var file = try Io.Dir.cwd().createFile(io, "seek.bin", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "abcd", 0);

    var reader_buffer: [0]u8 = .{};
    var reader = file.readerStreaming(io, &reader_buffer);
    try std.testing.expectError(error.Unseekable, reader.seekBy(-1));

    var read_out: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try reader.interface.readSliceShort(&read_out));
    try std.testing.expectEqualStrings("a", &read_out);
}

test "io: simulation streaming read faults leave cursor unchanged" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();

    var file = try Io.Dir.cwd().createFile(io, "read-fault.bin", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "abcdefgh", 0);

    var reader_buffer: [0]u8 = .{};
    var reader = file.readerStreaming(io, &reader_buffer);
    try reader.seekTo(2);

    try sim.control.disk.setFaults(.{ .read_error_rate = .always() });
    var read_out: [2]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, reader.interface.readSliceShort(&read_out));
    try std.testing.expectEqual(@as(u64, 2), reader.logicalPos());

    try sim.control.disk.setFaults(.{});
    try std.testing.expectEqual(@as(usize, 2), try file.readStreaming(io, &.{&read_out}));
    try std.testing.expectEqualStrings("cd", &read_out);
}

test "io: simulation streaming writes use disk pending-write crash semantics" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();

    var file = try Io.Dir.cwd().createFile(io, "pending.bin", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "abcd", 0);
    try file.sync(io);

    var writer_buffer: [0]u8 = .{};
    var writer = file.writerStreaming(io, &writer_buffer);
    try writer.seekTo(0);
    try writer.interface.writeAll("WXYZ");
    try writer.flush();

    try sim.control.disk.setFaults(.{ .crash_lost_write_rate = .always() });
    try sim.control.disk.crash();
    try sim.control.disk.restart();

    var read_out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try file.readPositionalAll(io, &read_out, 0));
    try std.testing.expectEqualStrings("abcd", &read_out);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash_write") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "result=lost") != null);
}

test "io: simulation files reopen tracked metadata" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();

    {
        var file = try Io.Dir.cwd().createFile(io, "state.bin", .{});
        defer file.close(io);
        try file.writePositionalAll(io, "ok", 0);
        try file.sync(io);
    }

    var reopened = try Io.Dir.cwd().openFile(io, "state.bin", .{ .allow_directory = false });
    defer reopened.close(io);
    try std.testing.expectEqual(@as(u64, 2), try reopened.length(io));
    const stat = try Io.Dir.cwd().statFile(io, "state.bin", .{});
    try std.testing.expectEqual(@as(u64, 2), stat.size);
    try std.testing.expectEqual(Io.Timestamp.zero, stat.atime);
    try std.testing.expect(stat.mtime.nanoseconds > 0);
    try std.testing.expectEqual(Io.Timestamp.zero, stat.ctime);
    try Io.Dir.cwd().access(io, "state.bin", .{ .read = true });

    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try reopened.readPositionalAll(io, &buffer, 0));
    try std.testing.expectEqualStrings("ok", &buffer);
}

test "io: simulation files zero sparse and extended ranges" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();

    var file = try Io.Dir.cwd().createFile(io, "sparse.bin", .{ .read = true });
    defer file.close(io);

    try file.writePositionalAll(io, "old-data", 0);
    try file.setLength(io, 0);
    try file.writePositionalAll(io, "x", 5);

    var sparse: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try file.readPositionalAll(io, &sparse, 0));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 'x' }, &sparse);

    try file.setLength(io, 9);
    var extended: [9]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 9), try file.readPositionalAll(io, &extended, 0));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 'x', 0, 0, 0 }, &extended);
}

test "io: simulation files delete and rename through disk authority" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();
    const cwd = Io.Dir.cwd();

    {
        var file = try cwd.createFile(io, "wal.log", .{ .read = true });
        defer file.close(io);
        try file.writePositionalAll(io, "abcd", 0);
        try file.sync(io);
    }

    try std.testing.expectEqual(@as(u64, 4), (try cwd.statFile(io, "wal.log", .{})).size);
    try cwd.rename("wal.log", cwd, "archive/wal.log", io);
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, "wal.log", .{}));
    try std.testing.expectEqual(@as(u64, 4), (try cwd.statFile(io, "archive/wal.log", .{})).size);

    var renamed = try cwd.openFile(io, "archive/wal.log", .{ .mode = .read_only });
    defer renamed.close(io);
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try renamed.readPositionalAll(io, &buffer, 0));
    try std.testing.expectEqualStrings("abcd", &buffer);

    var overwritten = try cwd.createFile(io, "replace.log", .{ .read = true });
    defer overwritten.close(io);
    try overwritten.writePositionalAll(io, "xxxx", 0);
    try overwritten.sync(io);

    try cwd.rename("archive/wal.log", cwd, "replace.log", io);
    try std.testing.expectError(error.AccessDenied, overwritten.length(io));
    try std.testing.expectError(error.FileNotFound, cwd.openFile(io, "archive/wal.log", .{}));

    var replaced = try cwd.openFile(io, "replace.log", .{ .mode = .read_only });
    defer replaced.close(io);
    try std.testing.expectEqual(@as(usize, 4), try replaced.readPositionalAll(io, &buffer, 0));
    try std.testing.expectEqualStrings("abcd", &buffer);

    try cwd.deleteFile(io, "replace.log");
    try std.testing.expectError(error.FileNotFound, cwd.openFile(io, "replace.log", .{}));
}

test "io: simulation tcp stream connects, accepts, reads, and writes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var backend = testIo(&world);
    defer backend.deinit();
    const io = backend.io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 1234) catch unreachable;
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    try std.testing.expectError(error.WouldBlock, server.accept(io));

    const client = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(io);

    const accepted = try server.accept(io);
    defer accepted.close(io);

    var empty_buffer: [1]u8 = undefined;
    var empty_read: [1][]u8 = .{&empty_buffer};
    try std.testing.expectError(error.Timeout, io.vtable.netRead(io.userdata, accepted.socket.handle, &empty_read));

    const client_data: [1][]const u8 = .{"ping"};
    try std.testing.expectEqual(@as(usize, 4), try io.vtable.netWrite(io.userdata, client.socket.handle, "", &client_data, 1));

    var server_buffer: [4]u8 = undefined;
    var server_data: [1][]u8 = .{&server_buffer};
    try std.testing.expectEqual(@as(usize, 4), try io.vtable.netRead(io.userdata, accepted.socket.handle, &server_data));
    try std.testing.expectEqualStrings("ping", &server_buffer);

    const server_reply: [1][]const u8 = .{"pong"};
    try std.testing.expectEqual(@as(usize, 4), try io.vtable.netWrite(io.userdata, accepted.socket.handle, "", &server_reply, 1));

    var client_buffer: [4]u8 = undefined;
    var client_read: [1][]u8 = .{&client_buffer};
    try std.testing.expectEqual(@as(usize, 4), try io.vtable.netRead(io.userdata, client.socket.handle, &client_read));
    try std.testing.expectEqualStrings("pong", &client_buffer);
}

test "io: simulation tcp stream fails closed for unknown addresses" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var backend = testIo(&world);
    defer backend.deinit();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 1234) catch unreachable;
    try std.testing.expectError(error.ConnectionRefused, address.connect(backend.io(), .{ .mode = .stream }));
}

test "io: world simulation exposes tcp backend through env" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4321) catch unreachable;
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const client = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(io);

    const accepted = try server.accept(io);
    defer accepted.close(io);
}
