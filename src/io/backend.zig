//! Deterministic `std.Io` backend coordinator for simulation worlds.
//!
//! This module owns shared handle state and the `std.Io.VTable`. File, network,
//! futex, and error-translation behavior lives in focused sibling modules.
//! Unsupported filesystem, process, and concurrency operations fail closed.

const std = @import("std");

const disk_module = @import("../disk/root.zig");
const file_module = @import("file.zig");
const futex_module = @import("futex.zig");
const net_module = @import("net.zig");
const network_module = @import("../network/root.zig");
const World = @import("../world.zig").World;

const Io = std.Io;
const SocketHandle = Io.net.Socket.Handle;

pub const FutexWaitResult = futex_module.FutexWaitResult;
pub const FutexWaitSet = futex_module.FutexWaitSet;

pub const Backend = struct {
    allocator: std.mem.Allocator,
    world: *World,
    disk: disk_module.Disk,
    sector_size: u64,
    network_control: network_module.AnyNetworkControl = network_module.AnyNetworkControl.unavailable(),
    next_network_node: network_module.NodeId = 0,
    futex_wait_set: ?FutexWaitSet = null,
    futex_keys: std.ArrayList(FutexKeyEntry) = .empty,
    next_futex_key: usize = 1,
    files: std.ArrayList(FileMeta) = .empty,
    handles: std.ArrayList(HandleEntry) = .empty,
    next_handle: SocketHandle = 1000,

    pub const HandleEntry = struct {
        handle: SocketHandle,
        state: State,

        pub const State = union(enum) {
            listener: *ListenerState,
            connection: *ConnectionState,
            file: *FileState,
        };
    };

    pub const FileMeta = struct {
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

    pub const ListenerState = struct {
        address: Io.net.IpAddress,
        node: ?network_module.NodeId = null,
        pending: std.ArrayList(SocketHandle) = .empty,
        closed: bool = false,
    };

    pub const ConnectionState = struct {
        address: Io.net.IpAddress,
        node: ?network_module.NodeId = null,
        inbox: std.ArrayList(u8) = .empty,
        read_error: ?Io.net.Stream.Reader.Error = null,
        peer: ?SocketHandle = null,
        delivery_floor_ns: u64 = 0,
        closed: bool = false,
    };

    pub const FileState = struct {
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

    pub fn attachNetworkControl(self: *Backend, control: network_module.AnyNetworkControl) void {
        self.network_control = control;
    }

    pub fn futexKey(self: *Backend, ptr: *const u32) usize {
        const address = @intFromPtr(ptr);
        for (self.futex_keys.items) |entry| {
            if (entry.address == address) return futex_module.waitKey(.futex, entry.key);
        }

        const key = self.next_futex_key;
        self.next_futex_key += 1;
        self.futex_keys.append(self.allocator, .{
            .address = address,
            .key = key,
        }) catch @panic("failed to allocate sim futex key");
        return futex_module.waitKey(.futex, key);
    }

    pub fn listenerWaitKey(_: *Backend, handle: SocketHandle) usize {
        return futex_module.waitKey(.listener, @intCast(handle));
    }

    pub fn connectionWaitKey(_: *Backend, handle: SocketHandle) usize {
        return futex_module.waitKey(.connection, @intCast(handle));
    }

    /// Wake tasks blocked on a connection handle becoming ready, if a
    /// scheduler is attached. No-op in the bare-backend case.
    pub fn wakeConnection(self: *Backend, handle: SocketHandle, count: usize) void {
        if (self.futex_wait_set) |wait_set| {
            _ = wait_set.wake(self.connectionWaitKey(handle), count);
        }
    }

    /// Wake tasks blocked on a listener handle becoming ready, if a
    /// scheduler is attached. No-op in the bare-backend case.
    pub fn wakeListener(self: *Backend, handle: SocketHandle, count: usize) void {
        if (self.futex_wait_set) |wait_set| {
            _ = wait_set.wake(self.listenerWaitKey(handle), count);
        }
    }

    pub fn allocateNetworkNode(self: *Backend) error{NetworkDown}!?network_module.NodeId {
        const process_count = network_module.processCountFromControl(self.network_control) orelse return null;
        if (@as(usize, self.next_network_node) >= process_count) return error.NetworkDown;
        const node = self.next_network_node;
        self.next_network_node += 1;
        return node;
    }

    pub fn createHandle(self: *Backend, state: HandleEntry.State) std.mem.Allocator.Error!SocketHandle {
        const handle = self.next_handle;
        self.next_handle += 1;
        try self.handles.append(self.allocator, .{
            .handle = handle,
            .state = state,
        });
        return handle;
    }

    pub fn findEntry(self: *Backend, handle: SocketHandle) ?*HandleEntry {
        for (self.handles.items) |*entry| {
            if (entry.handle == handle) return entry;
        }
        return null;
    }

    pub fn findOpenListener(self: *Backend, address: *const Io.net.IpAddress) ?*HandleEntry {
        for (self.handles.items) |*entry| switch (entry.state) {
            .listener => |listener_state| {
                if (!listener_state.closed and listener_state.address.eql(address)) return entry;
            },
            .connection => {},
            .file => {},
        };
        return null;
    }

    pub fn listener(self: *Backend, handle: SocketHandle) ?*ListenerState {
        return switch ((self.findEntry(handle) orelse return null).state) {
            .listener => |state| state,
            .connection, .file => null,
        };
    }

    pub fn connection(self: *Backend, handle: SocketHandle) ?*ConnectionState {
        return switch ((self.findEntry(handle) orelse return null).state) {
            .listener, .file => null,
            .connection => |state| state,
        };
    }

    pub fn file(self: *Backend, handle: Io.File.Handle) ?*FileState {
        return switch ((self.findEntry(@intCast(handle)) orelse return null).state) {
            .listener, .connection => null,
            .file => |state| state,
        };
    }

    pub fn fileMeta(self: *Backend, file_state: *const FileState) *FileMeta {
        return &self.files.items[file_state.file_index];
    }

    pub fn findFileMetaIndex(self: *Backend, path: []const u8) ?usize {
        for (self.files.items, 0..) |file_meta, index| {
            if (file_meta.deleted) continue;
            if (std.mem.eql(u8, file_meta.path, path)) return index;
        }
        return null;
    }

    pub fn createFileMeta(self: *Backend, path: []const u8) std.mem.Allocator.Error!usize {
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

    pub fn nowTimestamp(self: *const Backend) Io.Timestamp {
        return Io.Timestamp.fromNanoseconds(@intCast(self.world.now()));
    }

    pub fn closeFileHandlesForIndex(self: *Backend, file_index: usize) void {
        for (self.handles.items) |*entry| switch (entry.state) {
            .file => |file_state| {
                if (file_state.file_index == file_index) file_state.closed = true;
            },
            .listener, .connection => {},
        };
    }

    pub fn openFileHandle(
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

const file_ops = file_module.Ops(Backend);
const futex_ops = futex_module.Ops(Backend);
const net_ops = net_module.Ops(Backend);

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

    .futexWait = futex_ops.simFutexWait,
    .futexWaitUncancelable = futex_ops.simFutexWaitUncancelable,
    .futexWake = futex_ops.simFutexWake,

    .operate = simOperate,
    .batchAwaitAsync = Io.unreachableBatchAwaitAsync,
    .batchAwaitConcurrent = Io.unreachableBatchAwaitConcurrent,
    .batchCancel = Io.unreachableBatchCancel,

    .dirCreateDir = Io.failingDirCreateDir,
    .dirCreateDirPath = Io.failingDirCreateDirPath,
    .dirCreateDirPathOpen = Io.failingDirCreateDirPathOpen,
    .dirOpenDir = Io.failingDirOpenDir,
    .dirStat = Io.failingDirStat,
    .dirStatFile = file_ops.simDirStatFile,
    .dirAccess = file_ops.simDirAccess,
    .dirCreateFile = file_ops.simDirCreateFile,
    .dirCreateFileAtomic = Io.failingDirCreateFileAtomic,
    .dirOpenFile = file_ops.simDirOpenFile,
    .dirClose = file_ops.simDirClose,
    .dirRead = Io.noDirRead,
    .dirRealPath = Io.failingDirRealPath,
    .dirRealPathFile = Io.failingDirRealPathFile,
    .dirDeleteFile = file_ops.simDirDeleteFile,
    .dirDeleteDir = Io.failingDirDeleteDir,
    .dirRename = file_ops.simDirRename,
    .dirRenamePreserve = Io.failingDirRenamePreserve,
    .dirSymLink = Io.failingDirSymLink,
    .dirReadLink = Io.failingDirReadLink,
    .dirSetOwner = Io.failingDirSetOwner,
    .dirSetFileOwner = Io.failingDirSetFileOwner,
    .dirSetPermissions = Io.failingDirSetPermissions,
    .dirSetFilePermissions = Io.failingDirSetFilePermissions,
    .dirSetTimestamps = Io.noDirSetTimestamps,
    .dirHardLink = Io.failingDirHardLink,

    .fileStat = file_ops.simFileStat,
    .fileLength = file_ops.simFileLength,
    .fileClose = file_ops.simFileClose,
    .fileWritePositional = file_ops.simFileWritePositional,
    .fileWriteFileStreaming = Io.noFileWriteFileStreaming,
    .fileWriteFilePositional = Io.noFileWriteFilePositional,
    .fileReadPositional = file_ops.simFileReadPositional,
    .fileSeekBy = file_ops.simFileSeekBy,
    .fileSeekTo = file_ops.simFileSeekTo,
    .fileSync = file_ops.simFileSync,
    .fileIsTty = Io.unreachableFileIsTty,
    .fileEnableAnsiEscapeCodes = Io.unreachableFileEnableAnsiEscapeCodes,
    .fileSupportsAnsiEscapeCodes = Io.unreachableFileSupportsAnsiEscapeCodes,
    .fileSetLength = file_ops.simFileSetLength,
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

    .netListenIp = net_ops.simNetListenIp,
    .netAccept = net_ops.simNetAccept,
    .netBindIp = Io.failingNetBindIp,
    .netConnectIp = net_ops.simNetConnectIp,
    .netListenUnix = Io.failingNetListenUnix,
    .netConnectUnix = Io.failingNetConnectUnix,
    .netSocketCreatePair = Io.failingNetSocketCreatePair,
    .netSend = Io.failingNetSend,
    .netRead = net_ops.simNetRead,
    .netWrite = net_ops.simNetWrite,
    .netWriteFile = Io.failingNetWriteFile,
    .netClose = net_ops.simNetClose,
    .netShutdown = net_ops.simNetShutdown,
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

fn simOperate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    return switch (operation) {
        .file_read_streaming => |read| .{
            .file_read_streaming = file_ops.simFileReadStreaming(userdata, read.file, read.data),
        },
        .file_write_streaming => |write| .{
            .file_write_streaming = file_ops.simFileWriteStreaming(userdata, write.file, write.header, write.data, write.splat),
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
