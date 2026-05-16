//! Minimal deterministic `std.Io` backend for simulation worlds.
//!
//! This is the Phase 0 backend: deterministic clock and randomness, synchronous
//! `async`, a small in-memory TCP stream subset, and explicit failure for
//! filesystem/process operations.

const std = @import("std");

const World = @import("world.zig").World;

const Io = std.Io;
const SocketHandle = Io.net.Socket.Handle;

pub const Backend = struct {
    allocator: std.mem.Allocator,
    world: *World,
    handles: std.ArrayList(HandleEntry) = .empty,
    next_handle: SocketHandle = 1000,

    const HandleEntry = struct {
        handle: SocketHandle,
        state: State,

        const State = union(enum) {
            listener: *ListenerState,
            connection: *ConnectionState,
        };
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

    pub fn init(allocator: std.mem.Allocator, world: *World) Backend {
        return .{
            .allocator = allocator,
            .world = world,
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
        };
        self.handles.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn io(self: *Backend) Io {
        return .{
            .userdata = self,
            .vtable = &sim_vtable,
        };
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
        };
        return null;
    }

    fn listener(self: *Backend, handle: SocketHandle) ?*ListenerState {
        return switch ((self.findEntry(handle) orelse return null).state) {
            .listener => |state| state,
            .connection => null,
        };
    }

    fn connection(self: *Backend, handle: SocketHandle) ?*ConnectionState {
        return switch ((self.findEntry(handle) orelse return null).state) {
            .listener => null,
            .connection => |state| state,
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

    .futexWait = Io.noFutexWait,
    .futexWaitUncancelable = Io.noFutexWaitUncancelable,
    .futexWake = Io.noFutexWake,

    .operate = Io.failingOperate,
    .batchAwaitAsync = Io.unreachableBatchAwaitAsync,
    .batchAwaitConcurrent = Io.unreachableBatchAwaitConcurrent,
    .batchCancel = Io.unreachableBatchCancel,

    .dirCreateDir = Io.failingDirCreateDir,
    .dirCreateDirPath = Io.failingDirCreateDirPath,
    .dirCreateDirPathOpen = Io.failingDirCreateDirPathOpen,
    .dirOpenDir = Io.failingDirOpenDir,
    .dirStat = Io.failingDirStat,
    .dirStatFile = Io.failingDirStatFile,
    .dirAccess = Io.failingDirAccess,
    .dirCreateFile = Io.failingDirCreateFile,
    .dirCreateFileAtomic = Io.failingDirCreateFileAtomic,
    .dirOpenFile = Io.failingDirOpenFile,
    .dirClose = Io.unreachableDirClose,
    .dirRead = Io.noDirRead,
    .dirRealPath = Io.failingDirRealPath,
    .dirRealPathFile = Io.failingDirRealPathFile,
    .dirDeleteFile = Io.failingDirDeleteFile,
    .dirDeleteDir = Io.failingDirDeleteDir,
    .dirRename = Io.failingDirRename,
    .dirRenamePreserve = Io.failingDirRenamePreserve,
    .dirSymLink = Io.failingDirSymLink,
    .dirReadLink = Io.failingDirReadLink,
    .dirSetOwner = Io.failingDirSetOwner,
    .dirSetFileOwner = Io.failingDirSetFileOwner,
    .dirSetPermissions = Io.failingDirSetPermissions,
    .dirSetFilePermissions = Io.failingDirSetFilePermissions,
    .dirSetTimestamps = Io.noDirSetTimestamps,
    .dirHardLink = Io.failingDirHardLink,

    .fileStat = Io.failingFileStat,
    .fileLength = Io.failingFileLength,
    .fileClose = Io.unreachableFileClose,
    .fileWritePositional = Io.failingFileWritePositional,
    .fileWriteFileStreaming = Io.noFileWriteFileStreaming,
    .fileWriteFilePositional = Io.noFileWriteFilePositional,
    .fileReadPositional = Io.failingFileReadPositional,
    .fileSeekBy = Io.failingFileSeekBy,
    .fileSeekTo = Io.failingFileSeekTo,
    .fileSync = Io.failingFileSync,
    .fileIsTty = Io.unreachableFileIsTty,
    .fileEnableAnsiEscapeCodes = Io.unreachableFileEnableAnsiEscapeCodes,
    .fileSupportsAnsiEscapeCodes = Io.unreachableFileSupportsAnsiEscapeCodes,
    .fileSetLength = Io.failingFileSetLength,
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
        }
    }
}

fn simNetShutdown(userdata: ?*anyopaque, handle: SocketHandle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
    _ = how;
    simNetClose(userdata, (&handle)[0..1]);
}

fn testIo(world: *World) Backend {
    return .init(std.testing.allocator, world);
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
