//! Minimal deterministic `std.Io` backend for simulation worlds.
//!
//! This is the Phase 0 backend: deterministic clock and randomness, synchronous
//! `async`, and explicit failure for filesystem/network/process operations.

const std = @import("std");

const World = @import("world.zig").World;

const Io = std.Io;

pub fn fromWorld(world: *World) Io {
    return .{
        .userdata = world,
        .vtable = &sim_vtable,
    };
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

    .netListenIp = Io.failingNetListenIp,
    .netAccept = Io.failingNetAccept,
    .netBindIp = Io.failingNetBindIp,
    .netConnectIp = Io.failingNetConnectIp,
    .netListenUnix = Io.failingNetListenUnix,
    .netConnectUnix = Io.failingNetConnectUnix,
    .netSocketCreatePair = Io.failingNetSocketCreatePair,
    .netSend = Io.failingNetSend,
    .netRead = Io.failingNetRead,
    .netWrite = Io.failingNetWrite,
    .netWriteFile = Io.failingNetWriteFile,
    .netClose = Io.unreachableNetClose,
    .netShutdown = Io.failingNetShutdown,
    .netInterfaceNameResolve = Io.failingNetInterfaceNameResolve,
    .netInterfaceName = Io.unreachableNetInterfaceName,
    .netLookup = Io.failingNetLookup,
};

fn worldFromUserdata(userdata: ?*anyopaque) *World {
    return @ptrCast(@alignCast(userdata.?));
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

test "io: simulation clock and sleep use world time" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 5 });
    defer world.deinit();

    const io = fromWorld(&world);
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

    Io.random(fromWorld(&a), &a_bytes);
    Io.random(fromWorld(&b), &b_bytes);

    try std.testing.expectEqualSlices(u8, &a_bytes, &b_bytes);
}

test "io: simulation randomSecure is deterministic" {
    var a = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer a.deinit();
    var b = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer b.deinit();

    var a_bytes: [16]u8 = undefined;
    var b_bytes: [16]u8 = undefined;

    try Io.randomSecure(fromWorld(&a), &a_bytes);
    try Io.randomSecure(fromWorld(&b), &b_bytes);

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

    const io = fromWorld(&world);
    var future = Io.async(io, Helper.addOne, .{41});
    try std.testing.expectEqual(@as(u32, 42), future.await(io));
    try std.testing.expectError(error.ConcurrencyUnavailable, Io.concurrent(io, Helper.addOne, .{41}));
}

test "io: simulation cancellation checks are inert before fibers" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const io = fromWorld(&world);
    try Io.checkCancel(io);
    try std.testing.expectEqual(Io.CancelProtection.unblocked, Io.swapCancelProtection(io, .blocked));
    Io.recancel(io);
}

test "io: simulation queue works for immediately ready operations" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const io = fromWorld(&world);
    var backing: [4]u8 = undefined;
    var queue = Io.Queue(u8).init(&backing);

    try queue.putAll(io, &.{ 1, 2 });

    var out: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try queue.get(io, &out, 2));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &out);

    queue.close(io);
    try std.testing.expectError(error.Closed, queue.putOne(io, 3));
}

test "io: unsupported network fails closed" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 1234) catch unreachable;
    try std.testing.expectError(error.NetworkDown, address.connect(fromWorld(&world), .{ .mode = .stream }));
}
