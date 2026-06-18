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
const traceField = @import("../world.zig").traceField;

const Io = std.Io;
const SocketHandle = Io.net.Socket.Handle;

pub const FutexWaitResult = futex_module.FutexWaitResult;
pub const FutexWaitSet = futex_module.FutexWaitSet;
pub const TaskRuntime = @import("task.zig").TaskRuntime;

pub const Backend = struct {
    allocator: std.mem.Allocator,
    world: *World,
    disk: disk_module.Disk,
    sector_size: u64,
    network_control: network_module.AnyNetworkControl = network_module.AnyNetworkControl.unavailable(),
    process_registry: ?*ProcessRegistry = null,
    process_node: ?network_module.NodeId = null,
    next_network_node: network_module.NodeId = 0,
    futex_wait_set: ?FutexWaitSet = null,
    task_runtime: ?TaskRuntime = null,
    async_closures: std.ArrayList(*AsyncClosure) = .empty,
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
        /// Set when a disk crash invalidates cached state. The length is
        /// re-derived from disk truth on next touch; the timestamp is kept,
        /// since filesystem timestamps survive a real machine crash.
        stale: bool = false,

        fn deinit(self: *FileMeta, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            self.* = undefined;
        }
    };

    const FutexKeyEntry = struct {
        address: usize,
        key: usize,
    };

    pub const SocketRef = struct {
        backend: *Backend,
        handle: SocketHandle,
    };

    pub const ListenerRef = struct {
        backend: *Backend,
        handle: SocketHandle,
        state: *ListenerState,
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
        peer: ?SocketRef = null,
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
        for (self.async_closures.items) |closure| closure.destroy(self.allocator);
        self.async_closures.deinit(self.allocator);
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

    /// Attach a cooperative task runtime, enabling `Io.async` and
    /// `Io.concurrent` to spawn deterministic scheduler tasks.
    pub fn attachTaskRuntime(self: *Backend, runtime: TaskRuntime) void {
        self.task_runtime = runtime;
    }

    pub fn attachNetworkControl(self: *Backend, control: network_module.AnyNetworkControl) void {
        self.network_control = control;
    }

    pub fn attachProcessRegistry(self: *Backend, registry: *ProcessRegistry, node: network_module.NodeId) void {
        self.process_registry = registry;
        self.process_node = node;
    }

    pub fn futexKey(self: *Backend, ptr: *const u32) usize {
        if (self.process_registry) |registry| {
            const key = registry.futexKey(self, ptr) catch @panic("failed to allocate sim futex key");
            return futex_module.waitKey(.futex, key);
        }

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

    pub fn sleepWaitKey(_: *Backend) usize {
        return futex_module.waitKey(.sleep, 0);
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
        if (self.process_node) |node| {
            if (@as(usize, node) >= process_count) return error.NetworkDown;
            return node;
        }

        if (@as(usize, self.next_network_node) >= process_count) return error.NetworkDown;
        const node = self.next_network_node;
        self.next_network_node += 1;
        return node;
    }

    pub fn createHandle(self: *Backend, state: HandleEntry.State) std.mem.Allocator.Error!SocketHandle {
        const handle = if (self.process_registry) |registry|
            registry.allocateHandle()
        else handle: {
            const next = self.next_handle;
            self.next_handle += 1;
            break :handle next;
        };
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

    pub fn findOpenListenerRef(self: *Backend, address: *const Io.net.IpAddress) ?ListenerRef {
        if (self.process_registry) |registry| return registry.findOpenListener(address);
        const entry = self.findOpenListener(address) orelse return null;
        return .{
            .backend = self,
            .handle = entry.handle,
            .state = entry.state.listener,
        };
    }

    pub fn registerListener(self: *Backend, handle: SocketHandle, address: Io.net.IpAddress) std.mem.Allocator.Error!void {
        if (self.process_registry) |registry| {
            try registry.registerListener(self, handle, address);
        }
    }

    pub fn unregisterListener(self: *Backend, handle: SocketHandle) void {
        if (self.process_registry) |registry| registry.unregisterListener(self, handle);
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

    /// Find a tombstoned entry whose deletion may have been rolled back by
    /// a disk crash. Only stale tombstones qualify: a live tombstone is an
    /// authoritative deletion, but after a crash the disk may have
    /// resurrected the file.
    pub fn findStaleDeletedFileMetaIndex(self: *Backend, path: []const u8) ?usize {
        for (self.files.items, 0..) |file_meta, index| {
            if (!file_meta.deleted or !file_meta.stale) continue;
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

    /// Invalidate process-local state after a disk crash.
    ///
    /// A disk crash models a machine crash, which also kills the process:
    /// every open handle dies with it. File metadata is marked stale and
    /// re-derived from disk truth on first touch; timestamps are kept since
    /// filesystem timestamps survive a real machine crash.
    pub fn onDiskCrash(self: *Backend) void {
        for (self.handles.items) |*entry| switch (entry.state) {
            .file => |file_state| file_state.closed = true,
            .listener => |listener_state| {
                listener_state.closed = true;
                self.unregisterListener(entry.handle);
                self.wakeListener(entry.handle, std.math.maxInt(usize));
            },
            .connection => |connection_state| {
                connection_state.closed = true;
                self.wakeConnection(entry.handle, std.math.maxInt(usize));
                if (connection_state.peer) |peer| {
                    peer.backend.wakeConnection(peer.handle, std.math.maxInt(usize));
                }
            },
        };
        // Tombstones go stale too: a crash can roll back an unsynced
        // deletion, in which case the tombstoned entry must be revivable
        // with its timestamps intact.
        for (self.files.items) |*file_meta| {
            file_meta.stale = true;
        }
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

pub const ProcessRegistry = struct {
    allocator: std.mem.Allocator,
    listeners: std.ArrayList(ListenerRegistration) = .empty,
    futex_keys: std.ArrayList(FutexKeyRegistration) = .empty,
    next_futex_key: usize = 1,
    next_handle: SocketHandle = 1000,

    const ListenerRegistration = struct {
        backend: *Backend,
        handle: SocketHandle,
        address: Io.net.IpAddress,
    };

    const FutexKeyRegistration = struct {
        backend: *Backend,
        address: usize,
        key: usize,
    };

    pub fn init(allocator: std.mem.Allocator) ProcessRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProcessRegistry) void {
        self.futex_keys.deinit(self.allocator);
        self.listeners.deinit(self.allocator);
        self.* = undefined;
    }

    fn allocateHandle(self: *ProcessRegistry) SocketHandle {
        const handle = self.next_handle;
        self.next_handle += 1;
        return handle;
    }

    fn registerListener(
        self: *ProcessRegistry,
        backend: *Backend,
        handle: SocketHandle,
        address: Io.net.IpAddress,
    ) std.mem.Allocator.Error!void {
        try self.listeners.append(self.allocator, .{
            .backend = backend,
            .handle = handle,
            .address = address,
        });
    }

    fn unregisterListener(self: *ProcessRegistry, backend: *Backend, handle: SocketHandle) void {
        for (self.listeners.items, 0..) |entry, index| {
            if (entry.backend == backend and entry.handle == handle) {
                _ = self.listeners.swapRemove(index);
                return;
            }
        }
    }

    fn findOpenListener(self: *ProcessRegistry, address: *const Io.net.IpAddress) ?Backend.ListenerRef {
        for (self.listeners.items) |entry| {
            if (!entry.address.eql(address)) continue;
            const listener = entry.backend.listener(entry.handle) orelse continue;
            if (listener.closed) continue;
            return .{
                .backend = entry.backend,
                .handle = entry.handle,
                .state = listener,
            };
        }
        return null;
    }

    fn futexKey(self: *ProcessRegistry, backend: *Backend, ptr: *const u32) std.mem.Allocator.Error!usize {
        const address = @intFromPtr(ptr);
        for (self.futex_keys.items) |entry| {
            if (entry.backend == backend and entry.address == address) return entry.key;
        }

        const key = self.next_futex_key;
        self.next_futex_key += 1;
        try self.futex_keys.append(self.allocator, .{
            .backend = backend,
            .address = address,
            .key = key,
        });
        return key;
    }
};

pub const ProcessRuntime = struct {
    allocator: std.mem.Allocator,
    world: *World,
    disk: disk_module.Disk,
    sector_size: u64,
    registry: ProcessRegistry,
    backends: []Backend,

    pub fn init(
        self: *ProcessRuntime,
        allocator: std.mem.Allocator,
        world: *World,
        disk: disk_module.Disk,
        sector_size: u64,
        process_count: usize,
    ) std.mem.Allocator.Error!void {
        std.debug.assert(process_count > 0);

        const backends = try allocator.alloc(Backend, process_count);
        errdefer allocator.free(backends);

        self.* = .{
            .allocator = allocator,
            .world = world,
            .disk = disk,
            .sector_size = sector_size,
            .registry = .init(allocator),
            .backends = backends,
        };

        for (self.backends, 0..) |*backend, index| {
            backend.* = Backend.init(allocator, world, disk, sector_size);
            backend.attachProcessRegistry(&self.registry, @intCast(index));
        }
    }

    pub fn deinit(self: *ProcessRuntime) void {
        for (self.backends) |*backend| backend.deinit();
        self.allocator.free(self.backends);
        self.registry.deinit();
        self.* = undefined;
    }

    pub fn backendForNode(self: *ProcessRuntime, node: network_module.NodeId) error{InvalidNode}!*Backend {
        if (@as(usize, node) >= self.backends.len) return error.InvalidNode;
        return &self.backends[node];
    }

    pub fn io(self: *ProcessRuntime, node: network_module.NodeId) error{InvalidNode}!Io {
        return (try self.backendForNode(node)).io();
    }

    pub fn attachNetworkControl(self: *ProcessRuntime, control: network_module.AnyNetworkControl) void {
        for (self.backends) |*backend| backend.attachNetworkControl(control);
    }

    pub fn attachFutexWaitSet(self: *ProcessRuntime, wait_set: FutexWaitSet) void {
        for (self.backends) |*backend| backend.attachFutexWaitSet(wait_set);
    }

    pub fn attachTaskRuntime(self: *ProcessRuntime, runtime: TaskRuntime) void {
        for (self.backends) |*backend| backend.attachTaskRuntime(runtime);
    }

    pub fn onDiskCrash(self: *ProcessRuntime) void {
        for (self.backends) |*backend| backend.onDiskCrash();
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

pub fn onDiskCrashOpaque(ptr: *anyopaque) void {
    const backend: *Backend = @ptrCast(@alignCast(ptr));
    backend.onDiskCrash();
}

pub fn deinitProcessRuntimeOpaque(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const runtime: *ProcessRuntime = @ptrCast(@alignCast(ptr));
    runtime.deinit();
    allocator.destroy(runtime);
}

pub fn onProcessRuntimeDiskCrashOpaque(ptr: *anyopaque) void {
    const runtime: *ProcessRuntime = @ptrCast(@alignCast(ptr));
    runtime.onDiskCrash();
}

const sim_vtable: Io.VTable = .{
    .crashHandler = Io.noCrashHandler,

    .async = simAsync,
    .concurrent = simConcurrent,
    .await = simAwait,
    .cancel = simCancel,

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

/// Heap record backing one spawned `Io.async`/`Io.concurrent` task.
///
/// Context and result are stored out-of-line because the caller's context
/// buffer expires when the vtable call returns, while the result must
/// survive until `await`/`cancel` collects it.
const AsyncClosure = struct {
    backend: *Backend,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    task_id: u64 = 0,
    done: bool = false,
    context: []align(max_async_alignment) u8,
    result: []align(max_async_alignment) u8,

    /// Upper bound for context/result alignment, matching std's own
    /// fiber-backed backends. Asserted at spawn.
    const max_async_alignment = 16;

    fn create(
        backend: *Backend,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) error{OutOfMemory}!*AsyncClosure {
        std.debug.assert(result_alignment.toByteUnits() <= max_async_alignment);
        std.debug.assert(context_alignment.toByteUnits() <= max_async_alignment);

        const closure = try backend.allocator.create(AsyncClosure);
        errdefer backend.allocator.destroy(closure);
        const context_copy = try backend.allocator.alignedAlloc(u8, .fromByteUnits(max_async_alignment), context.len);
        errdefer backend.allocator.free(context_copy);
        const result = try backend.allocator.alignedAlloc(u8, .fromByteUnits(max_async_alignment), result_len);
        errdefer backend.allocator.free(result);

        @memcpy(context_copy, context);
        closure.* = .{
            .backend = backend,
            .start = start,
            .context = context_copy,
            .result = result,
        };
        return closure;
    }

    fn destroy(self: *AsyncClosure, allocator: std.mem.Allocator) void {
        allocator.free(self.context);
        allocator.free(self.result);
        allocator.destroy(self);
    }

    fn completionKey(self: *const AsyncClosure) usize {
        return futex_module.waitKey(.task, @intCast(self.task_id));
    }

    /// Task entry: run the user function, then publish completion.
    fn run(raw: *anyopaque) void {
        const closure: *AsyncClosure = @ptrCast(@alignCast(raw));
        closure.start(closure.context.ptr, closure.result.ptr);
        closure.done = true;
        const runtime = closure.backend.task_runtime orelse unreachable;
        _ = runtime.wake(closure.completionKey(), std.math.maxInt(usize));
    }
};

fn simAsync(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Io.AnyFuture {
    return simConcurrent(userdata, result.len, result_alignment, context, context_alignment, start) catch {
        // No task runtime attached: run eagerly on the caller, preserving
        // `async` semantics (concurrency is optional for it).
        start(context.ptr, result.ptr);
        return null;
    };
}

fn simConcurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*Io.AnyFuture {
    const backend = backendFromUserdata(userdata);
    const runtime = backend.task_runtime orelse return error.ConcurrencyUnavailable;

    const closure = AsyncClosure.create(
        backend,
        result_len,
        result_alignment,
        context,
        context_alignment,
        start,
    ) catch return error.ConcurrencyUnavailable;
    errdefer closure.destroy(backend.allocator);

    backend.async_closures.append(backend.allocator, closure) catch return error.ConcurrencyUnavailable;
    errdefer _ = backend.async_closures.pop();

    // A cooperative task is a unit of concurrency in the deterministic
    // simulation: it makes progress whenever the caller suspends, which is
    // what `concurrent` requires of single-threaded executors.
    closure.task_id = try runtime.spawn(AsyncClosure.run, closure);
    return @ptrCast(closure);
}

fn simAwait(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    _ = result_alignment;
    const backend = backendFromUserdata(userdata);
    const closure: *AsyncClosure = @ptrCast(@alignCast(any_future));
    // `await` is only called when `async` returned non-null, so a runtime
    // was attached at spawn time.
    const runtime = backend.task_runtime orelse unreachable;

    if (!closure.done) {
        if (runtime.inTask()) {
            while (!closure.done) runtime.block(closure.completionKey());
        } else {
            runtime.runUntilDone(&closure.done);
        }
    }

    @memcpy(result, closure.result[0..result.len]);
    releaseClosure(backend, closure);
}

fn simCancel(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    // Cooperative tasks cannot be preempted, and the deterministic model has
    // no external event that could interrupt them mid-run: cancellation runs
    // the task to completion, exactly like `await`.
    simAwait(userdata, any_future, result, result_alignment);
}

fn releaseClosure(backend: *Backend, closure: *AsyncClosure) void {
    for (backend.async_closures.items, 0..) |candidate, index| {
        if (candidate == closure) {
            _ = backend.async_closures.swapRemove(index);
            break;
        }
    }
    closure.destroy(backend.allocator);
}

fn simRandom(userdata: ?*anyopaque, buffer: []u8) void {
    const world = worldFromUserdata(userdata);
    world.unsafeUntracedRandom().bytes(buffer);

    // Trace the draw so replay divergence is visible at the draw site. The
    // digest stands in for the bytes: byte-identical draws produce
    // byte-identical trace lines without inflating traces by buffer size.
    // Wyhash with a fixed seed is deterministic across runs and platforms.
    const digest = std.hash.Wyhash.hash(0, buffer);
    world.recordFields("io.random", &.{
        traceField("len", .{ .uint = @intCast(buffer.len) }),
        traceField("digest", .{ .uint = digest }),
    }) catch @panic("failed to record simulated io random");
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
    const backend = backendFromUserdata(userdata);
    const world = backend.world;
    const deadline_ns = switch (timeout) {
        .none => return,
        .duration => |duration| b: {
            if (!supportsClock(duration.clock)) return;
            if (duration.raw.nanoseconds <= 0) return;
            const delta = std.math.cast(u64, duration.raw.nanoseconds) orelse
                @panic("simulated sleep duration exceeds clock range");
            break :b std.math.add(u64, world.now(), delta) catch
                @panic("simulated sleep deadline exceeds clock range");
        },
        .deadline => |deadline| b: {
            if (!supportsClock(deadline.clock)) return;
            const deadline_ns = std.math.cast(u64, deadline.raw.nanoseconds) orelse return;
            if (deadline_ns <= world.now()) return;
            break :b deadline_ns;
        },
    };

    if (backend.futex_wait_set) |wait_set| {
        // All sleepers share one wait key, so a wake on that key (nothing
        // issues one today) must not end a sleep early. Re-park until the
        // deadline has actually passed; the scheduler returns `timed_out`
        // immediately once it has.
        while (world.now() < deadline_ns) {
            _ = wait_set.blockUntil(backend.sleepWaitKey(), deadline_ns);
        }
        return;
    }

    const duration_ns = world.clock().ceilDuration(deadline_ns - world.now());
    world.runFor(duration_ns) catch @panic("failed to record simulated sleep");
}
