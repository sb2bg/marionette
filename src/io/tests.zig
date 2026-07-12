const std = @import("std");

const Backend = @import("backend.zig").Backend;
const clock_module = @import("../clock.zig");
const disk_module = @import("../disk/root.zig");
const env_module = @import("../env.zig");
const network_module = @import("../network/root.zig");
const world_module = @import("../world.zig");
const World = world_module.World;
const Io = std.Io;

fn testIo(world: *World) Backend {
    return .init(std.testing.allocator, world, disk_module.Disk.unavailable(), 4096);
}

fn noopProcessRestart(_: *anyopaque, _: env_module.Env) anyerror!void {}

fn registerNoopProcess(sim: World.Simulation, node: network_module.NodeId) !void {
    try sim.registerProcess(node, .{
        .ptr = sim.control.world,
        .restart = noopProcessRestart,
    });
}

const PostCreateStatFailDisk = struct {
    fn disk(self: *@This()) disk_module.Disk {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: disk_module.Disk.VTable = .{
        .read = read,
        .write = write,
        .sync = sync,
        .sync_dir = syncDir,
        .stat = stat,
        .read_some = readSome,
        .set_length = setLength,
        .delete = delete,
        .rename = rename,
        .create_dir = createDir,
        .stat_dir = statDir,
        .read_dir = readDir,
    };

    fn read(_: *anyopaque, _: disk_module.Disk.Read) disk_module.DiskError!void {
        return error.FileNotFound;
    }

    fn write(_: *anyopaque, _: disk_module.Disk.Write) disk_module.DiskError!void {}

    fn sync(_: *anyopaque, _: disk_module.Disk.Sync) disk_module.DiskError!void {
        return error.FileNotFound;
    }

    fn syncDir(_: *anyopaque, _: disk_module.Disk.SyncDir) disk_module.DiskError!void {}

    fn stat(_: *anyopaque, _: disk_module.Disk.Stat) disk_module.DiskError!disk_module.Disk.StatResult {
        return error.FileNotFound;
    }

    fn readSome(_: *anyopaque, _: disk_module.Disk.ReadSome) disk_module.DiskError!usize {
        return error.FileNotFound;
    }

    fn setLength(_: *anyopaque, _: disk_module.Disk.SetLength) disk_module.DiskError!void {
        return error.FileNotFound;
    }

    fn delete(_: *anyopaque, _: disk_module.Disk.Delete) disk_module.DiskError!void {
        return error.FileNotFound;
    }

    fn rename(_: *anyopaque, _: disk_module.Disk.Rename) disk_module.DiskError!void {
        return error.FileNotFound;
    }

    fn createDir(_: *anyopaque, _: disk_module.Disk.CreateDir) disk_module.DiskError!void {}

    fn statDir(_: *anyopaque, options: disk_module.Disk.StatDir) disk_module.DiskError!disk_module.Disk.StatDirResult {
        if (std.mem.eql(u8, options.path, ".")) {
            return .{ .inode = 1, .mtime_ns = 0 };
        }
        return error.FileNotFound;
    }

    fn readDir(_: *anyopaque, options: disk_module.Disk.ReadDir) disk_module.DiskError!disk_module.Disk.DirList {
        return .{
            .allocator = options.allocator,
            .entries = try options.allocator.alloc(disk_module.Disk.DirEntry, 0),
        };
    }
};

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        count += 1;
        start = index + needle.len;
    }
    return count;
}

test "io: simulation sleep rounds to clock resolution and records time movement" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var backend = testIo(&world);
    defer backend.deinit();
    const io = backend.io();
    try std.testing.expectEqual(@as(i96, 0), Io.Clock.awake.now(io).nanoseconds);
    try std.testing.expectEqual(@as(i96, 10), (try Io.Clock.awake.resolution(io)).nanoseconds);

    try Io.sleep(io, .fromNanoseconds(15), .awake);
    try std.testing.expectEqual(@as(i96, 20), Io.Clock.awake.now(io).nanoseconds);
    try std.testing.expect(std.mem.indexOf(
        u8,
        world.traceBytes(),
        "world.run_for start_ns=0 duration_ns=20 end_ns=20",
    ) != null);
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
    try std.testing.expect(std.mem.indexOf(u8, a.traceBytes(), "io.random len=16 digest=") != null);
    try std.testing.expectEqualStrings(a.traceBytes(), b.traceBytes());
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

test "io: failed post-create stat does not publish file metadata" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var disk = PostCreateStatFailDisk{};
    var backend = Backend.init(std.testing.allocator, &world, disk.disk(), 4096);
    defer backend.deinit();
    const io = backend.io();

    try std.testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().createFile(io, "ghost", .{}),
    );
    try std.testing.expectEqual(@as(usize, 1), backend.files.items.len);
    try std.testing.expect(backend.files.items[0].deleted);

    try std.testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(io, "ghost", .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().openFile(io, "ghost", .{}),
    );
}

const fiber_supported = @import("../fiber.zig").supported;

/// Fiber stacks carry a zeroed sentinel root frame, so stack-tracing
/// allocators (std.testing.allocator captures a trace on every alloc and
/// free) work from inside scheduler tasks and leak checking stays on.
const task_world_allocator = std.testing.allocator;

test "io: world simulation runs async tasks deterministically" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn addOne(value: u32) u32 {
            return value + 1;
        }
    };

    var first_trace: []u8 = undefined;
    var second_trace: []u8 = undefined;
    for ([2]*[]u8{ &first_trace, &second_trace }) |trace_out| {
        var world = try World.init(task_world_allocator, .{ .seed = 0xA51, .tick_ns = 10 });
        defer world.deinit();

        const sim = try world.simulate(.{});
        const io = sim.env.io();

        var future = Io.async(io, Helper.addOne, .{41});
        try std.testing.expectEqual(@as(u32, 42), future.await(io));

        var concurrent_future = try Io.concurrent(io, Helper.addOne, .{8});
        try std.testing.expectEqual(@as(u32, 9), concurrent_future.await(io));

        try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "scheduler.spawn task=0") != null);
        try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "scheduler.complete task=1") != null);
        trace_out.* = try std.testing.allocator.dupe(u8, world.traceBytes());
    }
    defer std.testing.allocator.free(first_trace);
    defer std.testing.allocator.free(second_trace);

    try std.testing.expectEqualStrings(first_trace, second_trace);
}

test "io: task groups await deterministic completion and can be reused" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn appendAfter(
            io: Io,
            delay_ns: u64,
            output: *[3]u8,
            output_len: *usize,
            value: u8,
        ) void {
            Io.sleep(io, .fromNanoseconds(delay_ns), .awake) catch unreachable;
            output[output_len.*] = value;
            output_len.* += 1;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA5B, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var output: [3]u8 = undefined;
    var output_len: usize = 0;
    var group: Io.Group = .init;
    try group.concurrent(io, Helper.appendAfter, .{ io, 30, &output, &output_len, 'a' });
    try group.concurrent(io, Helper.appendAfter, .{ io, 10, &output, &output_len, 'b' });
    try group.await(io);
    try std.testing.expectEqualStrings("ba", output[0..output_len]);

    group.async(io, Helper.appendAfter, .{ io, 10, &output, &output_len, 'c' });
    try group.await(io);
    try std.testing.expectEqualStrings("bac", output[0..output_len]);
}

test "io: process kill completes owned task groups" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn delayedWrite(io: Io, completed: *bool) void {
            Io.sleep(io, .fromNanoseconds(100), .awake) catch unreachable;
            completed.* = true;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA5C, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var completed = false;
    var group: Io.Group = .init;
    try group.concurrent(io, Helper.delayedWrite, .{ io, &completed });
    try sim.killProcess(0);
    try group.await(io);
    try std.testing.expect(!completed);
    const backend = try world_module.internal.ioRuntime(sim).backendForNode(0);
    try std.testing.expectEqual(@as(usize, 0), backend.group_closures.items.len);
}

test "io: process kill sweeps disk op scratch from killed tasks" {
    if (!fiber_supported) return error.SkipZigTest;

    const Scenario = struct {
        sim: World.Simulation,
        io: Io,
        started: u32 = 0,
        scratch_before_kill: usize = 0,
        scratch_after_kill: usize = std.math.maxInt(usize),

        fn writer(self: *@This()) void {
            self.started = 1;
            self.io.futexWake(u32, &self.started, std.math.maxInt(u32));
            _ = Io.Dir.cwd().openFile(self.io, "missing.txt", .{}) catch {};
        }

        fn killer(self: *@This()) void {
            while (self.started == 0) {
                self.io.futexWait(u32, &self.started, 0) catch @panic("futex wait failed");
            }
            const backend = world_module.internal.ioRuntime(self.sim).backendForNode(0) catch
                @panic("missing process backend");
            self.scratch_before_kill = backend.op_scratch.items.len;
            self.sim.killProcess(0) catch @panic("process kill failed");
            self.scratch_after_kill = backend.op_scratch.items.len;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA66, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var scenario: Scenario = .{ .sim = sim, .io = io };
    var writer = Io.async(io, Scenario.writer, .{&scenario});
    var killer = Io.async(io, Scenario.killer, .{&scenario});

    killer.await(io);
    writer.await(io);
    try std.testing.expect(scenario.scratch_before_kill > 0);
    try std.testing.expectEqual(@as(usize, 0), scenario.scratch_after_kill);
}

test "io: task group completion keys are unique across processes" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn delayedNoop(io: Io) void {
            Io.sleep(io, .fromNanoseconds(100), .awake) catch unreachable;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA5D, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();

    var first: Io.Group = .init;
    var second: Io.Group = .init;
    try first.concurrent(node_zero_io, Helper.delayedNoop, .{node_zero_io});
    try second.concurrent(node_one_io, Helper.delayedNoop, .{node_one_io});

    const first_backend = try world_module.internal.ioRuntime(sim).backendForNode(0);
    const second_backend = try world_module.internal.ioRuntime(sim).backendForNode(1);
    try std.testing.expectEqual(@as(usize, 1), first_backend.group_states.items.len);
    try std.testing.expectEqual(@as(usize, 1), second_backend.group_states.items.len);
    try std.testing.expect(first_backend.group_states.items[0].id != second_backend.group_states.items[0].id);

    try first.await(node_zero_io);
    try second.await(node_one_io);
}

test "io: async tasks can await other async tasks" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn inner(value: u32) u32 {
            return value * 2;
        }

        fn outer(io: Io, value: u32) u32 {
            var future = Io.async(io, inner, .{value});
            return future.await(io) + 1;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA52, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var future = Io.async(io, Helper.outer, .{ io, 20 });
    try std.testing.expectEqual(@as(u32, 41), future.await(io));
    // The outer task parked on the inner task's completion key.
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "scheduler.block task=0") != null);
}

test "io: async tasks interleave through sleeps and replay byte-identically" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn slowDouble(io: Io, value: u32) u32 {
            Io.sleep(io, .fromNanoseconds(30), .awake) catch unreachable;
            return value * 2;
        }

        fn fastTriple(io: Io, value: u32) u32 {
            Io.sleep(io, .fromNanoseconds(10), .awake) catch unreachable;
            return value * 3;
        }
    };

    var first_trace: []u8 = undefined;
    var second_trace: []u8 = undefined;
    for ([2]*[]u8{ &first_trace, &second_trace }) |trace_out| {
        var world = try World.init(task_world_allocator, .{ .seed = 0xA53, .tick_ns = 10 });
        defer world.deinit();

        const sim = try world.simulate(.{});
        const io = sim.env.io();

        var slow = Io.async(io, Helper.slowDouble, .{ io, 5 });
        var fast = Io.async(io, Helper.fastTriple, .{ io, 5 });
        try std.testing.expectEqual(@as(u32, 10), slow.await(io));
        try std.testing.expectEqual(@as(u32, 15), fast.await(io));
        try std.testing.expectEqual(@as(u64, 30), world.now());

        try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "scheduler.timeout task=1 deadline_ns=10") != null);
        try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "scheduler.timeout task=0 deadline_ns=30") != null);
        trace_out.* = try std.testing.allocator.dupe(u8, world.traceBytes());
    }
    defer std.testing.allocator.free(first_trace);
    defer std.testing.allocator.free(second_trace);

    try std.testing.expectEqualStrings(first_trace, second_trace);
}

test "io: main-context sleep through simulate env advances time" {
    if (!fiber_supported) return error.SkipZigTest;

    // Regression: attaching the world-owned scheduler must not turn
    // main-context blocking into a "block outside a scheduled task" panic.
    var world = try World.init(task_world_allocator, .{ .seed = 0xA55, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    try Io.sleep(io, .fromNanoseconds(30), .awake);
    try std.testing.expectEqual(@as(u64, 30), world.now());
}

test "io: main-context sleep runs background tasks to their deadlines" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn napTen(io: Io) u64 {
            Io.sleep(io, .fromNanoseconds(10), .awake) catch unreachable;
            return 7;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA56, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var future = Io.async(io, Helper.napTen, .{io});
    // Main sleeps past the task's deadline: the task must wake at 10, not
    // be skipped over while main-context time advances.
    try Io.sleep(io, .fromNanoseconds(40), .awake);
    try std.testing.expectEqual(@as(u64, 40), world.now());
    try std.testing.expectEqual(@as(u64, 7), future.await(io));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "scheduler.timeout task=0 deadline_ns=10") != null);
}

test "io: main-context futex wait times out through simulate env" {
    if (!fiber_supported) return error.SkipZigTest;

    var world = try World.init(task_world_allocator, .{ .seed = 0xA57, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var value: u32 = 0;
    try io.futexWaitTimeout(u32, &value, 0, .{ .duration = .{
        .raw = .fromNanoseconds(20),
        .clock = .awake,
    } });
    try std.testing.expectEqual(@as(u64, 20), world.now());
}

test "io: main-context net accept is woken by a connecting task" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn connector(io: Io, address: Io.net.IpAddress) void {
            Io.sleep(io, .fromNanoseconds(20), .awake) catch unreachable;
            const stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch
                @panic("connect failed");
            stream.close(io);
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA58, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4571) catch unreachable;
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    var future = Io.async(io, Helper.connector, .{ io, address });
    // Main blocks in accept; the scheduler runs the connector task, which
    // wakes the listener key.
    const accepted = try server.accept(io);
    accepted.close(io);
    future.await(io);
    try std.testing.expectEqual(@as(u64, 20), world.now());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "scheduler.wake_main key=") != null);
}

test "io: std.Io.net reconnects reuse process node identity" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xA5A, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4572) catch unreachable;
    var server = try address.listen(server_io, .{});
    defer server.deinit(server_io);

    for (0..3) |_| {
        const client = try address.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
        const accepted = try server.accept(server_io);
        client.close(client_io);
        accepted.close(server_io);
    }
}

test "io: overlapping std.Io.net connections route bytes by socket handle" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xA5F, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 8 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4575) catch unreachable;
    var server = try address.listen(server_io, .{});
    defer server.deinit(server_io);

    const client_a = try address.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
    defer client_a.close(client_io);
    const server_a = try server.accept(server_io);
    defer server_a.close(server_io);

    const client_b = try address.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
    defer client_b.close(client_io);
    const server_b = try server.accept(server_io);
    defer server_b.close(server_io);

    var writer_a = client_a.writer(client_io, &.{});
    try writer_a.interface.writeAll("aa");
    try writer_a.interface.flush();

    var writer_b = client_b.writer(client_io, &.{});
    try writer_b.interface.writeAll("bb");
    try writer_b.interface.flush();

    var reader_b = server_b.reader(server_io, &.{});
    var out_b: [2]u8 = undefined;
    try reader_b.interface.readSliceAll(&out_b);
    try std.testing.expectEqualStrings("bb", &out_b);

    var reader_a = server_a.reader(server_io, &.{});
    var out_a: [2]u8 = undefined;
    try reader_a.interface.readSliceAll(&out_a);
    try std.testing.expectEqualStrings("aa", &out_a);
}

test "io: envForNode rejects nodes outside the configured topology" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xA5D, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    try std.testing.expectError(error.InvalidNode, sim.envForNode(2));
}

test "io: sim env io is node zero" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xA60, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const default_io = sim.env.io();
    const node_zero_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4576) catch unreachable;
    var server = try address.listen(default_io, .{});
    defer server.deinit(default_io);

    const client = try address.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(client_io);
    const accepted = try server.accept(node_zero_io);
    defer accepted.close(node_zero_io);
}

test "io: duplicate listeners are rejected across process backends" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xA61, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4577) catch unreachable;
    var server = try address.listen(server_io, .{});
    defer server.deinit(server_io);

    try std.testing.expectError(error.AddressInUse, address.listen(client_io, .{}));
}

test "io: listen on port 0 allocates distinct ephemeral ports" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xA6A, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server_a = try address.listen(io, .{});
    defer server_a.deinit(io);
    var server_b = try address.listen(io, .{});
    defer server_b.deinit(io);

    const port_a = server_a.socket.address.getPort();
    const port_b = server_b.socket.address.getPort();
    try std.testing.expect(port_a >= Backend.ephemeral_port_min);
    try std.testing.expect(port_b >= Backend.ephemeral_port_min);
    try std.testing.expect(port_a != port_b);
}

test "io: ephemeral listener accepts connections to its assigned port" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xA6B, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const bind_address = Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try bind_address.listen(server_io, .{});
    defer server.deinit(server_io);

    const assigned = server.socket.address;
    try std.testing.expect(assigned.getPort() != 0);

    const client = try assigned.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(client_io);
    const accepted = try server.accept(server_io);
    defer accepted.close(server_io);
}

test "io: process futex keys are namespaced by backend" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn waitForFlag(io: Io, flag: *u32) void {
            while (flag.* == 0) {
                io.futexWait(u32, flag, 0) catch @panic("futex wait failed");
            }
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA5C, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    var flag: u32 = 0;
    var future = Io.async(client_io, Helper.waitForFlag, .{ client_io, &flag });
    try std.testing.expectError(error.Deadlock, sim.control.runTasksUntilIdle());
    try std.testing.expectEqual(@as(usize, 1), sim.control.blockedTaskCount());
    try std.testing.expectEqual(@as(usize, 1), world_module.internal.ioRuntime(sim).registry.futex_keys.items.len);

    flag = 1;
    server_io.futexWake(u32, &flag, 1);
    try std.testing.expectError(error.Deadlock, sim.control.runTasksUntilIdle());
    try std.testing.expectEqual(@as(usize, 1), sim.control.blockedTaskCount());
    try std.testing.expectEqual(@as(usize, 1), world_module.internal.ioRuntime(sim).registry.futex_keys.items.len);

    client_io.futexWake(u32, &flag, 1);
    future.await(client_io);
    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
    try std.testing.expectEqual(@as(usize, 0), world_module.internal.ioRuntime(sim).registry.futex_keys.items.len);
}

test "io: completed futex waits retire process key records" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn waitForFlag(io: Io, flag: *u32) void {
            while (flag.* == 0) {
                io.futexWait(u32, flag, 0) catch @panic("futex wait failed");
            }
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA5D, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var flag: u32 = 0;
    var first = Io.async(io, Helper.waitForFlag, .{ io, &flag });
    var second = Io.async(io, Helper.waitForFlag, .{ io, &flag });
    try std.testing.expectError(error.Deadlock, sim.control.runTasksUntilIdle());
    try std.testing.expectEqual(@as(usize, 2), sim.control.blockedTaskCount());
    try std.testing.expectEqual(@as(usize, 1), world_module.internal.ioRuntime(sim).registry.futex_keys.items.len);

    flag = 1;
    io.futexWake(u32, &flag, 1);
    try std.testing.expectError(error.Deadlock, sim.control.runTasksUntilIdle());
    try std.testing.expectEqual(@as(usize, 1), sim.control.blockedTaskCount());
    try std.testing.expectEqual(@as(usize, 1), world_module.internal.ioRuntime(sim).registry.futex_keys.items.len);

    io.futexWake(u32, &flag, 1);
    try sim.control.runTasksUntilIdle();
    first.await(io);
    second.await(io);
    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
    try std.testing.expectEqual(@as(usize, 0), world_module.internal.ioRuntime(sim).registry.futex_keys.items.len);

    io.futexWake(u32, &flag, 1);
    try std.testing.expectEqual(@as(usize, 0), world_module.internal.ioRuntime(sim).registry.futex_keys.items.len);
}

test "io: process kill retires futex keys for killed waiters" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn waitForFlag(io: Io, flag: *u32) void {
            while (flag.* == 0) {
                io.futexWait(u32, flag, 0) catch @panic("futex wait failed");
            }
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA65, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var flag: u32 = 0;
    var future = Io.async(io, Helper.waitForFlag, .{ io, &flag });
    try std.testing.expectError(error.Deadlock, sim.control.runTasksUntilIdle());
    try std.testing.expectEqual(@as(usize, 1), sim.control.blockedTaskCount());
    try std.testing.expectEqual(@as(usize, 1), world_module.internal.ioRuntime(sim).registry.futex_keys.items.len);

    try sim.killProcess(0);
    future.await(io);
    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
    try std.testing.expectEqual(@as(usize, 0), world_module.internal.ioRuntime(sim).registry.futex_keys.items.len);
}

test "io: disk crash closes process-local std.Io.net listeners" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xA5B, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    const server_backend = try world_module.internal.ioRuntime(sim).backendForNode(0);

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4573) catch unreachable;
    var server = try address.listen(server_io, .{});
    defer server.deinit(server_io);
    try std.testing.expectEqual(@as(usize, 1), server_backend.handles.items.len);

    try sim.control.disk.crash();
    try sim.control.disk.restart();
    try std.testing.expectEqual(@as(usize, 0), server_backend.handles.items.len);

    try std.testing.expectError(
        error.NetworkDown,
        address.connect(client_io, .{ .mode = .stream, .protocol = .tcp }),
    );
    try std.testing.expectError(error.SocketNotListening, server.accept(server_io));
}

test "io: disk crash wakes std.Io.net accept waiters" {
    if (!fiber_supported) return error.SkipZigTest;

    const Scenario = struct {
        io: Io,
        listener: Io.net.Server,
        waiting: u32 = 0,
        accept_error: ?Io.net.Server.AcceptError = null,

        fn acceptTask(self: *@This()) void {
            self.waiting = 1;
            self.io.futexWake(u32, &self.waiting, 1);
            _ = self.listener.accept(self.io) catch |err| {
                self.accept_error = err;
                return;
            };
            @panic("accept unexpectedly succeeded after crash");
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA62, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const server_io = (try sim.envForNode(0)).io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4578) catch unreachable;
    var listener = try address.listen(server_io, .{});
    defer listener.deinit(server_io);

    var scenario: Scenario = .{ .io = server_io, .listener = listener };
    var future = Io.async(server_io, Scenario.acceptTask, .{&scenario});
    while (scenario.waiting == 0) {
        server_io.futexWait(u32, &scenario.waiting, 0) catch @panic("futex wait failed");
    }

    try sim.control.disk.crash();
    try sim.control.disk.restart();

    future.await(server_io);
    try std.testing.expectEqual(@as(?Io.net.Server.AcceptError, null), scenario.accept_error);
    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "scheduler.complete task=") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "status=killed") != null);
}

test "io: disk crash closes live std.Io.net connections and wakes readers" {
    if (!fiber_supported) return error.SkipZigTest;

    const Scenario = struct {
        server_io: Io,
        client_io: Io,
        listener: Io.net.Server,
        address: Io.net.IpAddress,
        accepted: u32 = 0,
        read_started: u32 = 0,
        crashed: u32 = 0,
        read_error: ?Io.net.Stream.Reader.Error = null,

        fn signal(io: Io, flag: *u32) void {
            flag.* = 1;
            io.futexWake(u32, flag, std.math.maxInt(u32));
        }

        fn waitFor(io: Io, flag: *u32) void {
            while (flag.* == 0) {
                io.futexWait(u32, flag, 0) catch @panic("futex wait failed");
            }
        }

        fn serverTask(self: *@This()) void {
            const stream = self.listener.accept(self.server_io) catch @panic("accept failed");
            defer stream.close(self.server_io);
            signal(self.server_io, &self.accepted);

            var buffer: [1]u8 = undefined;
            var buffers: [1][]u8 = .{&buffer};
            signal(self.server_io, &self.read_started);
            _ = self.server_io.vtable.netRead(
                self.server_io.userdata,
                stream.socket.handle,
                &buffers,
            ) catch |err| {
                self.read_error = err;
                return;
            };
            @panic("read unexpectedly succeeded after crash");
        }

        fn clientTask(self: *@This()) void {
            const stream = self.address.connect(self.client_io, .{ .mode = .stream, .protocol = .tcp }) catch @panic("connect failed");
            defer stream.close(self.client_io);
            waitFor(self.server_io, &self.read_started);
            waitFor(self.server_io, &self.crashed);
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA5E, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4574) catch unreachable;
    var listener = try address.listen(server_io, .{});
    defer listener.deinit(server_io);

    var scenario: Scenario = .{
        .server_io = server_io,
        .client_io = client_io,
        .listener = listener,
        .address = address,
    };

    var server_future = Io.async(server_io, Scenario.serverTask, .{&scenario});
    var client_future = Io.async(client_io, Scenario.clientTask, .{&scenario});

    Scenario.waitFor(server_io, &scenario.accepted);
    Scenario.waitFor(server_io, &scenario.read_started);

    try sim.control.disk.crash();
    try sim.control.disk.restart();
    Scenario.signal(server_io, &scenario.crashed);

    client_future.await(client_io);
    server_future.await(server_io);
    try std.testing.expectEqual(@as(?Io.net.Stream.Reader.Error, null), scenario.read_error);
    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "process.kill node=0 reason=disk_crash") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "process.kill node=1 reason=disk_crash") != null);
}

test "io: process kill cancels owned tasks and resets peers" {
    if (!fiber_supported) return error.SkipZigTest;

    const Scenario = struct {
        server_io: Io,
        client_io: Io,
        listener: Io.net.Server,
        address: Io.net.IpAddress,
        accepted: u32 = 0,
        read_started: u32 = 0,
        stop: u32 = 0,
        read_error: ?Io.net.Stream.Reader.Error = null,

        fn signal(io: Io, flag: *u32) void {
            flag.* = 1;
            io.futexWake(u32, flag, std.math.maxInt(u32));
        }

        fn waitFor(io: Io, flag: *u32) void {
            while (flag.* == 0) {
                io.futexWait(u32, flag, 0) catch @panic("futex wait failed");
            }
        }

        fn serverTask(self: *@This()) void {
            const stream = self.listener.accept(self.server_io) catch @panic("accept failed");
            _ = stream;
            signal(self.server_io, &self.accepted);
            waitFor(self.server_io, &self.stop);
        }

        fn clientTask(self: *@This()) void {
            const stream = self.address.connect(self.client_io, .{ .mode = .stream, .protocol = .tcp }) catch @panic("connect failed");
            defer stream.close(self.client_io);
            waitFor(self.server_io, &self.accepted);

            var buffer: [1]u8 = undefined;
            var buffers: [1][]u8 = .{&buffer};
            signal(self.client_io, &self.read_started);
            _ = self.client_io.vtable.netRead(
                self.client_io.userdata,
                stream.socket.handle,
                &buffers,
            ) catch |err| {
                self.read_error = err;
                return;
            };
            @panic("read unexpectedly succeeded after process kill");
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA5F, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4575) catch unreachable;
    var listener = try address.listen(server_io, .{});
    defer listener.deinit(server_io);

    var scenario: Scenario = .{
        .server_io = server_io,
        .client_io = client_io,
        .listener = listener,
        .address = address,
    };

    var server_future = Io.async(server_io, Scenario.serverTask, .{&scenario});
    var client_future = Io.async(client_io, Scenario.clientTask, .{&scenario});

    Scenario.waitFor(server_io, &scenario.accepted);
    Scenario.waitFor(client_io, &scenario.read_started);

    try sim.killProcess(0);

    client_future.await(client_io);
    server_future.await(server_io);
    try std.testing.expectEqual(error.ConnectionResetByPeer, scenario.read_error.?);
    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "process.kill node=0 reason=manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "status=killed") != null);
}

test "io: cross-process await releases the spawning backend closure" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn addOne(value: u32) u32 {
            return value + 1;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA63, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    var future = Io.async(server_io, Helper.addOne, .{41});
    try std.testing.expectEqual(@as(u32, 42), future.await(client_io));

    const server_backend = try world_module.internal.ioRuntime(sim).backendForNode(0);
    const client_backend = try world_module.internal.ioRuntime(sim).backendForNode(1);
    try std.testing.expectEqual(@as(usize, 0), server_backend.async_closures.items.len);
    try std.testing.expectEqual(@as(usize, 0), client_backend.async_closures.items.len);

    try sim.killProcess(0);
}

test "io: process kill from inside owned task completes as killed" {
    if (!fiber_supported) return error.SkipZigTest;

    const Scenario = struct {
        sim: World.Simulation,
        after_kill_call: bool = false,

        fn task(self: *@This()) void {
            self.sim.killProcess(0) catch @panic("self kill failed");
            self.after_kill_call = true;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA64, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var scenario: Scenario = .{ .sim = sim };
    var future = Io.async(io, Scenario.task, .{&scenario});
    future.await(io);

    try std.testing.expect(scenario.after_kill_call);
    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "process.kill node=0 reason=manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "status=killed") != null);
}

test "io: process restart reruns registered initializer against durable state" {
    if (!fiber_supported) return error.SkipZigTest;

    const State = struct {
        starts: u32 = 0,
        kills: u32 = 0,
        volatile_value: u32 = 99,
        last_bytes: [4]u8 = @splat(0),

        fn onKill(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.kills += 1;
            self.volatile_value = 0;
        }

        fn restart(raw: *anyopaque, env: env_module.Env) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const io = env.io();
            var file = try Io.Dir.cwd().openFile(io, "restart.bin", .{ .mode = .read_only });
            defer file.close(io);

            try std.testing.expectEqual(@as(usize, 4), try file.readPositionalAll(io, &self.last_bytes, 0));
            if (!std.mem.eql(u8, &self.last_bytes, "live")) return error.BadRestartData;
            self.starts += 1;
            self.volatile_value = 7;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA60, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();

    var file = try Io.Dir.cwd().createFile(io, "restart.bin", .{ .read = true });
    try file.writePositionalAll(io, "live", 0);
    try file.sync(io);
    file.close(io);

    var state: State = .{};
    try sim.registerProcess(0, .{
        .ptr = &state,
        .on_kill = State.onKill,
        .restart = State.restart,
    });

    try sim.killProcess(0);
    try sim.killProcess(0);
    try std.testing.expectEqual(@as(u32, 1), state.kills);
    try std.testing.expectEqual(@as(u32, 0), state.volatile_value);
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(world.traceBytes(), "process.kill node=0 reason=manual"),
    );

    try sim.restartProcess(0);
    try std.testing.expectEqual(@as(u32, 1), state.starts);
    try std.testing.expectEqual(@as(u32, 1), state.kills);
    try std.testing.expectEqual(@as(u32, 7), state.volatile_value);
    try std.testing.expectEqualStrings("live", &state.last_bytes);

    try sim.restartProcess(0);
    try std.testing.expectEqual(@as(u32, 2), state.starts);
    try std.testing.expectEqual(@as(u32, 2), state.kills);
    try std.testing.expectEqual(@as(u32, 7), state.volatile_value);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "process.restart node=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "process.kill node=0 reason=restart") != null);
}

test "io: killed processes reject saved node capabilities until restart" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn identity(value: u32) u32 {
            return value;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA64, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 1 } });
    const saved_env = try sim.envForNode(0);
    const saved_io = saved_env.io();
    try registerNoopProcess(sim, 0);

    try sim.killProcess(0);

    try std.testing.expectError(error.ProcessKilled, sim.envForNode(0));
    try std.testing.expectError(
        error.AccessDenied,
        Io.Dir.cwd().createFile(saved_io, "while-killed", .{}),
    );
    try std.testing.expectError(
        error.ConcurrencyUnavailable,
        Io.concurrent(saved_io, Helper.identity, .{1}),
    );
    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    try std.testing.expectError(error.NetworkDown, address.listen(saved_io, .{}));

    try sim.restartProcess(0);
    var file = try Io.Dir.cwd().createFile(saved_io, "after-restart", .{});
    file.close(saved_io);
    var listener = try address.listen(saved_io, .{});
    listener.deinit(saved_io);
}

test "io: manual restart invalidates process-local file metadata" {
    const State = struct {
        observed_len: u64 = 0,

        fn restart(raw: *anyopaque, env: env_module.Env) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const io = env.io();
            var file = try Io.Dir.cwd().openFile(io, "shared", .{ .mode = .read_only });
            defer file.close(io);
            self.observed_len = try file.length(io);
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA641, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();

    var file = try Io.Dir.cwd().createFile(node_zero_io, "shared", .{ .read = true });
    try file.writePositionalAll(node_zero_io, "old!", 0);
    try file.sync(node_zero_io);
    file.close(node_zero_io);
    try std.testing.expectEqual(@as(u64, 4), (try Io.Dir.cwd().statFile(node_zero_io, "shared", .{})).size);

    var state: State = .{};
    try sim.registerProcess(0, .{ .ptr = &state, .restart = State.restart });
    try sim.killProcess(0);

    var updater = try Io.Dir.cwd().openFile(node_one_io, "shared", .{ .mode = .read_write });
    try updater.writePositionalAll(node_one_io, "new!", 4);
    try updater.sync(node_one_io);
    updater.close(node_one_io);

    try sim.restartProcess(0);
    try std.testing.expectEqual(@as(u64, 8), state.observed_len);
}

test "io: failed restart rolls back partial process resources" {
    if (!fiber_supported) return error.SkipZigTest;

    const State = struct {
        fail: bool = true,
        kills: u32 = 0,
        starts: u32 = 0,

        fn onKill(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.kills += 1;
        }

        fn restart(raw: *anyopaque, env: env_module.Env) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4581) catch unreachable;
            var listener = try address.listen(env.io(), .{});
            if (self.fail) return error.RestartFailed;
            listener.deinit(env.io());
            self.starts += 1;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA642, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 1 } });
    const saved_io = sim.env.io();
    var state: State = .{};
    try sim.registerProcess(0, .{
        .ptr = &state,
        .on_kill = State.onKill,
        .restart = State.restart,
    });

    try sim.killProcess(0);
    try std.testing.expectError(error.RestartFailed, sim.restartProcess(0));

    const backend = try world_module.internal.ioRuntime(sim).backendForNode(0);
    try std.testing.expectEqual(@as(usize, 0), backend.handles.items.len);
    try std.testing.expectEqual(@as(u32, 2), state.kills);
    try std.testing.expectError(error.ProcessKilled, sim.envForNode(0));
    try std.testing.expectError(
        error.AccessDenied,
        Io.Dir.cwd().createFile(saved_io, "still-killed", .{}),
    );

    state.fail = false;
    try sim.restartProcess(0);
    try std.testing.expectEqual(@as(u32, 1), state.starts);
}

test "io: restarting an unregistered process does not kill it" {
    if (!fiber_supported) return error.SkipZigTest;

    const State = struct {
        starts: u32 = 0,
        kills: u32 = 0,

        fn onKill(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.kills += 1;
        }

        fn restart(raw: *anyopaque, _: env_module.Env) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.starts += 1;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA65, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    try std.testing.expectError(error.ProcessNotRegistered, sim.restartProcess(0));

    var state: State = .{};
    try sim.registerProcess(0, .{
        .ptr = &state,
        .on_kill = State.onKill,
        .restart = State.restart,
    });

    try sim.restartProcess(0);
    try std.testing.expectEqual(@as(u32, 1), state.starts);
    try std.testing.expectEqual(@as(u32, 1), state.kills);
}

test "io: process dynamics validate rates and tick-aligned durations" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xA66, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});

    try std.testing.expectError(
        error.InvalidRate,
        sim.control.process.setDynamics(0, .{
            .crash_rate = .{ .numerator = 2, .denominator = 1 },
        }),
    );
    try std.testing.expectError(
        error.InvalidDuration,
        sim.control.process.setDynamics(0, .{
            .crash_rate = .always(),
            .crash_stability_min_ns = 11,
        }),
    );
    try std.testing.expectError(
        error.InvalidNode,
        sim.control.process.setDynamics(1, .{ .crash_rate = .always() }),
    );
}

test "io: process transition beyond clock range does not fail an earlier run" {
    const start_ns = std.math.maxInt(clock_module.Timestamp) - 25;
    var world = try World.init(task_world_allocator, .{
        .seed = 0xA661,
        .start_ns = start_ns,
        .tick_ns = 10,
    });
    defer world.deinit();

    const sim = try world.simulate(.{});
    try sim.control.process.setDynamics(0, .{
        .crash_rate = .always(),
        .crash_stability_min_ns = 30,
    });

    try sim.control.runFor(10);

    try std.testing.expectEqual(start_ns + 10, world.now());
    try std.testing.expect(std.mem.indexOf(
        u8,
        world.traceBytes(),
        "process.kill node=0 reason=auto_crash",
    ) == null);
}

test "io: process dynamics crash and restart at control boundaries" {
    if (!fiber_supported) return error.SkipZigTest;

    const State = struct {
        starts: u32 = 0,
        kills: u32 = 0,

        fn onKill(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.kills += 1;
        }

        fn restart(raw: *anyopaque, _: env_module.Env) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.starts += 1;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA67, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    var state: State = .{};
    try sim.registerProcess(0, .{
        .ptr = &state,
        .on_kill = State.onKill,
        .restart = State.restart,
    });
    try sim.control.process.setDynamics(0, .{
        .crash_rate = .always(),
        .restart_rate = .always(),
        .crash_stability_min_ns = 20,
        .restart_stability_min_ns = 30,
    });

    try sim.control.runFor(10);
    try std.testing.expectEqual(@as(u32, 0), state.kills);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 10), world.now());

    try sim.control.runFor(10);
    try std.testing.expectEqual(@as(u32, 1), state.kills);
    try std.testing.expectEqual(@as(u32, 0), state.starts);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 20), world.now());

    try sim.control.runFor(30);
    try std.testing.expectEqual(@as(u32, 1), state.kills);
    try std.testing.expectEqual(@as(u32, 1), state.starts);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 50), world.now());

    const trace = world.traceBytes();
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, trace, "world.tick"));
    try std.testing.expect(std.mem.indexOf(u8, trace, "process.dynamics node=0 crash_rate=1/1 restart_rate=1/1 crash_stability_min_ns=20 restart_stability_min_ns=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "world.run_for start_ns=10 duration_ns=10 end_ns=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "process.kill node=0 reason=auto_crash") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "world.run_for start_ns=20 duration_ns=30 end_ns=50") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "process.restart node=0 automatic=true") != null);
}

fn runProcessDynamicsTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    const State = struct {
        fn onKill(_: *anyopaque) void {}
        fn restart(_: *anyopaque, _: env_module.Env) anyerror!void {}
    };

    var world = try World.init(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    var state: u8 = 0;
    try sim.registerProcess(0, .{
        .ptr = &state,
        .on_kill = State.onKill,
        .restart = State.restart,
    });
    try sim.control.process.setDynamics(0, .{
        .crash_rate = .oneIn(2),
        .restart_rate = .oneIn(2),
        .crash_stability_min_ns = 10,
        .restart_stability_min_ns = 10,
    });
    try sim.control.runFor(500);

    return try allocator.dupe(u8, world.traceBytes());
}

test "io: process dynamics are deterministic for the same seed" {
    if (!fiber_supported) return error.SkipZigTest;

    const a = try runProcessDynamicsTrace(std.testing.allocator, 0xA68);
    defer std.testing.allocator.free(a);
    const b = try runProcessDynamicsTrace(std.testing.allocator, 0xA68);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.indexOf(u8, a, "world.random_int_less_than") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "process.kill node=0 reason=auto_crash") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "process.restart node=0 automatic=true") != null);
}

fn runCombinedFaultEvolutionTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    const State = struct {
        fn onKill(_: *anyopaque) void {}
        fn restart(_: *anyopaque, _: env_module.Env) anyerror!void {}
    };

    var world = try World.init(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{
        .network = .{
            .nodes = 3,
            .service_nodes = 2,
            .path_capacity = 4,
        },
    });
    var state: u8 = 0;
    try sim.registerProcess(0, .{
        .ptr = &state,
        .on_kill = State.onKill,
        .restart = State.restart,
    });
    try sim.control.network.setPartitionDynamics(.{
        .partition_rate = .always(),
        .unpartition_rate = .always(),
        .partition_stability_min_ns = 3_000,
        .unpartition_stability_min_ns = 2_000,
    });
    try sim.control.process.setDynamics(0, .{
        .crash_rate = .always(),
        .restart_rate = .always(),
        .crash_stability_min_ns = 2_000,
        .restart_stability_min_ns = 3_000,
    });

    try sim.control.runFor(10_000);
    return try allocator.dupe(u8, world.traceBytes());
}

fn expectFaultTransitionsFollowTracedBoundaries(trace: []const u8) !void {
    var boundary_since_time_advance = false;
    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "world.run_for") != null) {
            boundary_since_time_advance = false;
        } else if (std.mem.indexOf(u8, line, "fault_evolution.boundary") != null) {
            boundary_since_time_advance = true;
        } else if (std.mem.indexOf(u8, line, "world.random_int_less_than") != null or
            std.mem.indexOf(u8, line, "network.auto_partition") != null or
            std.mem.indexOf(u8, line, "network.auto_heal") != null or
            std.mem.indexOf(u8, line, "process.kill node=0 reason=auto_crash") != null or
            std.mem.indexOf(u8, line, "process.restart node=0 automatic=true") != null)
        {
            try std.testing.expect(boundary_since_time_advance);
        }
    }
}

test "io: fixed fault participants evolve together across a large quiet jump" {
    if (!fiber_supported) return error.SkipZigTest;

    const a = try runCombinedFaultEvolutionTrace(std.testing.allocator, 0xA6A);
    defer std.testing.allocator.free(a);
    const b = try runCombinedFaultEvolutionTrace(std.testing.allocator, 0xA6A);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
    try expectFaultTransitionsFollowTracedBoundaries(a);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, a, "world.tick"));
    try std.testing.expect(std.mem.count(u8, a, "world.run_for") < 20);
    try std.testing.expect(std.mem.indexOf(u8, a, "network.auto_partition") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "network.auto_heal") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "process.kill node=0 reason=auto_crash") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "process.restart node=0 automatic=true") != null);
}

test "io: scheduler timer jumps evolve process and network faults" {
    if (!fiber_supported) return error.SkipZigTest;

    const State = struct {
        kills: u32 = 0,
        restarted_task_ran_at: ?clock_module.Timestamp = null,

        fn onKill(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.kills += 1;
        }

        fn restartedTask(self: *@This(), clock: env_module.Clock) void {
            if (self.restarted_task_ran_at == null) {
                self.restarted_task_ran_at = clock.now();
            }
        }

        fn restart(raw: *anyopaque, env: env_module.Env) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try Io.concurrent(env.io(), restartedTask, .{ self, env.clock });
        }

        fn sleep(io: Io) void {
            Io.sleep(io, .fromNanoseconds(100), .awake) catch unreachable;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA6B, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{
        .network = .{ .nodes = 2, .service_nodes = 2, .path_capacity = 4 },
    });
    var state: State = .{};
    try sim.registerProcess(1, .{
        .ptr = &state,
        .on_kill = State.onKill,
        .restart = State.restart,
    });
    try sim.control.process.setDynamics(1, .{
        .crash_rate = .always(),
        .restart_rate = .always(),
        .crash_stability_min_ns = 10,
        .restart_stability_min_ns = 10,
    });
    try sim.control.network.setPartitionDynamics(.{
        .partition_rate = .always(),
        .partition_stability_min_ns = 20,
    });

    const io = sim.env.io();
    var sleeper = Io.async(io, State.sleep, .{io});
    sleeper.await(io);

    try std.testing.expectEqual(@as(clock_module.Timestamp, 100), world.now());
    try std.testing.expectEqual(@as(u32, 5), state.kills);
    try std.testing.expectEqual(@as(?clock_module.Timestamp, 20), state.restarted_task_ran_at);
    const trace = world.traceBytes();
    const run_to_crash = std.mem.indexOf(u8, trace, "world.run_for start_ns=0 duration_ns=10 end_ns=10").?;
    const crash = std.mem.indexOf(u8, trace, "process.kill node=1 reason=auto_crash").?;
    const run_to_partition = std.mem.indexOf(u8, trace, "world.run_for start_ns=10 duration_ns=10 end_ns=20").?;
    const partition = std.mem.indexOf(u8, trace, "network.auto_partition").?;
    try std.testing.expect(run_to_crash < crash);
    try std.testing.expect(crash < run_to_partition);
    try std.testing.expect(run_to_partition < partition);
}

test "io: automatic process restart reports missing lifecycle" {
    if (!fiber_supported) return error.SkipZigTest;

    var world = try World.init(task_world_allocator, .{ .seed = 0xA69, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    try sim.control.process.setDynamics(0, .{ .restart_rate = .always() });
    try sim.control.process.kill(0);

    try std.testing.expectError(error.ProcessNotRegistered, sim.control.runFor(10));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "process.kill node=0 reason=manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "process.restart node=0") == null);
}

test "io: completed async tasks release their fiber stacks" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn noop() void {}
    };

    var counting = std.testing.allocator_instance;
    _ = &counting;

    var world = try World.init(task_world_allocator, .{ .seed = 0xA59, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    // Many sequential spawn/await cycles: with eager fiber reclamation the
    // resident cost per completed task is one small Task record, not a
    // 256 KiB stack. (Stacks are mmap'd, so the testing allocator cannot
    // observe them; this exercises the loop and the scheduler invariants.)
    for (0..64) |_| {
        var future = Io.async(io, Helper.noop, .{});
        future.await(io);
    }
}

test "io: unawaited async tasks are reclaimed at world teardown" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn noop() void {}
    };

    var world = try World.init(std.testing.allocator, .{ .seed = 0xA54, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    // Spawn without awaiting: the closure must be freed by backend deinit
    // (the testing allocator fails this test on a leak).
    _ = try Io.concurrent(io, Helper.noop, .{});
}

test "io: simulation cancellation checks are inert without a scheduler" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var backend = testIo(&world);
    defer backend.deinit();
    const io = backend.io();
    try Io.checkCancel(io);
    try std.testing.expectEqual(Io.CancelProtection.unblocked, Io.swapCancelProtection(io, .blocked));
    Io.recancel(io);
}

test "io: task_stack_size option carries tasks past the default stack" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn deepStack() u64 {
            // A frame deeper than the default 1 MiB task stack: this only
            // completes when the configured 4 MiB stack actually reached
            // the spawned task.
            var buffer: [2 * 1024 * 1024]u8 = undefined;
            @memset(&buffer, 0xAB);
            std.mem.doNotOptimizeAway(&buffer);
            return buffer[buffer.len - 1];
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0x57AC, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .task_stack_size = 4 * 1024 * 1024 });
    const io = sim.env.io();

    var future = try Io.concurrent(io, Helper.deepStack, .{});
    try std.testing.expectEqual(@as(u64, 0xAB), future.await(io));
}

const CancelCheckState = struct {
    first_canceled: bool = false,
    second_ok: bool = false,
    rearmed_canceled: bool = false,
};

fn cancelCheckTask(io: Io, state: *CancelCheckState) Io.Cancelable!u32 {
    Io.checkCancel(io) catch {
        state.first_canceled = true;
        // Delivery is one-shot: the next point must not re-signal.
        try Io.checkCancel(io);
        state.second_ok = true;
        // `recancel` re-arms the request for the next point.
        Io.recancel(io);
        Io.checkCancel(io) catch {
            state.rearmed_canceled = true;
            return error.Canceled;
        };
        return 0;
    };
    return 41;
}

fn runCancelCheckTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var world = try World.init(task_world_allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var state = CancelCheckState{};
    var future = try Io.concurrent(io, cancelCheckTask, .{ io, &state });
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expect(state.first_canceled);
    try std.testing.expect(state.second_ok);
    try std.testing.expect(state.rearmed_canceled);

    return try allocator.dupe(u8, world.traceBytes());
}

test "io: cancel delivers once at checkCancel and recancel re-arms" {
    if (!fiber_supported) return error.SkipZigTest;

    const first = try runCancelCheckTrace(std.testing.allocator, 0xCA9CE1);
    defer std.testing.allocator.free(first);
    const second = try runCancelCheckTrace(std.testing.allocator, 0xCA9CE1);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.cancel_request task=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.cancel_deliver task=0") != null);
}

test "io: cancel protection defers delivery until unblocked" {
    if (!fiber_supported) return error.SkipZigTest;

    const State = struct {
        leaked_through_protection: bool = false,
        delivered_after_unprotect: bool = false,
    };
    const Helper = struct {
        fn protected(io: Io, state: *State) Io.Cancelable!u32 {
            const old = Io.swapCancelProtection(io, .blocked);
            if (old != .unblocked) return 1;
            Io.checkCancel(io) catch {
                state.leaked_through_protection = true;
                return error.Canceled;
            };
            const swapped = Io.swapCancelProtection(io, .unblocked);
            if (swapped != .blocked) return 2;
            Io.checkCancel(io) catch {
                state.delivered_after_unprotect = true;
                return error.Canceled;
            };
            return 3;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xB10CED, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var state = State{};
    var future = try Io.concurrent(io, Helper.protected, .{ io, &state });
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expect(!state.leaked_through_protection);
    try std.testing.expect(state.delivered_after_unprotect);
}

const FutexCancelState = struct {
    futex: u32 = 0,
    parked_canceled: bool = false,
    cancel_result_canceled: bool = false,
};

fn futexCancelParker(io: Io, state: *FutexCancelState) Io.Cancelable!void {
    io.futexWait(u32, &state.futex, 0) catch |err| {
        state.parked_canceled = true;
        return err;
    };
}

fn futexCancelCanceler(
    io: Io,
    future: *Io.Future(Io.Cancelable!void),
    state: *FutexCancelState,
) void {
    // Sleep before canceling: ready tasks run before timers advance, so the
    // parker is guaranteed parked on its futex by the time this resumes.
    Io.sleep(io, .fromNanoseconds(50), .awake) catch unreachable;
    future.cancel(io) catch {
        state.cancel_result_canceled = true;
    };
}

fn runFutexCancelTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var world = try World.init(task_world_allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var state = FutexCancelState{};
    var park_future = try Io.concurrent(io, futexCancelParker, .{ io, &state });
    var cancel_future = try Io.concurrent(io, futexCancelCanceler, .{ io, &park_future, &state });
    cancel_future.await(io);

    try std.testing.expect(state.parked_canceled);
    try std.testing.expect(state.cancel_result_canceled);
    return try allocator.dupe(u8, world.traceBytes());
}

test "io: cancel unparks a task blocked in futexWait" {
    if (!fiber_supported) return error.SkipZigTest;

    const first = try runFutexCancelTrace(std.testing.allocator, 0xFA7E);
    defer std.testing.allocator.free(first);
    const second = try runFutexCancelTrace(std.testing.allocator, 0xFA7E);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.cancel_request task=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.cancel_deliver task=0") != null);
}

test "io: cancel unparks a sleeping task before its deadline" {
    if (!fiber_supported) return error.SkipZigTest;

    const State = struct {
        sleep_canceled: bool = false,
    };
    const Helper = struct {
        fn sleeper(io: Io, state: *State) Io.Cancelable!void {
            Io.sleep(io, .fromNanoseconds(1_000_000), .awake) catch |err| {
                state.sleep_canceled = true;
                return err;
            };
        }

        fn canceler(io: Io, future: *Io.Future(Io.Cancelable!void)) void {
            Io.sleep(io, .fromNanoseconds(50), .awake) catch unreachable;
            _ = future.cancel(io) catch {};
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0x51EE9, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var state = State{};
    var sleep_future = try Io.concurrent(io, Helper.sleeper, .{ io, &state });
    var cancel_future = try Io.concurrent(io, Helper.canceler, .{ io, &sleep_future });
    cancel_future.await(io);

    try std.testing.expect(state.sleep_canceled);
    // The sleeper was interrupted, not timed out: the million-nanosecond
    // deadline is still far in the simulated future.
    try std.testing.expect(world.now() < 1_000_000);
}

test "io: uncancelable futex waits defer delivery to the next cancellation point" {
    if (!fiber_supported) return error.SkipZigTest;

    const State = struct {
        futex: u32 = 0,
        woken_normally: bool = false,
        canceled_at_check: bool = false,
    };
    const Helper = struct {
        fn parker(io: Io, state: *State) Io.Cancelable!void {
            io.futexWaitUncancelable(u32, &state.futex, 0);
            state.woken_normally = true;
            Io.checkCancel(io) catch |err| {
                state.canceled_at_check = true;
                return err;
            };
        }

        fn canceler(io: Io, future: *Io.Future(Io.Cancelable!void)) void {
            Io.sleep(io, .fromNanoseconds(50), .awake) catch unreachable;
            // The parker is in an uncancelable wait: this arms the request
            // and blocks awaiting; it must not interrupt the wait.
            _ = future.cancel(io) catch {};
        }

        fn waker(io: Io, state: *State) void {
            Io.sleep(io, .fromNanoseconds(200), .awake) catch unreachable;
            state.futex = 1;
            io.futexWake(u32, &state.futex, 1);
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0x0DDF, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var state = State{};
    var park_future = try Io.concurrent(io, Helper.parker, .{ io, &state });
    var cancel_future = try Io.concurrent(io, Helper.canceler, .{ io, &park_future });
    var wake_future = try Io.concurrent(io, Helper.waker, .{ io, &state });
    cancel_future.await(io);
    wake_future.await(io);

    try std.testing.expect(state.woken_normally);
    try std.testing.expect(state.canceled_at_check);
}

test "io: cancel unparks a task blocked in net accept" {
    if (!fiber_supported) return error.SkipZigTest;

    const State = struct {
        accept_canceled: bool = false,
    };
    const Helper = struct {
        fn acceptor(io: Io, server: *Io.net.Server, state: *State) Io.Cancelable!void {
            const stream = server.accept(io) catch |err| switch (err) {
                error.Canceled => {
                    state.accept_canceled = true;
                    return error.Canceled;
                },
                else => return,
            };
            stream.close(io);
        }

        fn canceler(io: Io, future: *Io.Future(Io.Cancelable!void)) void {
            Io.sleep(io, .fromNanoseconds(50), .awake) catch unreachable;
            _ = future.cancel(io) catch {};
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xACC7, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const server_io = (try sim.envForNode(0)).io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4590) catch unreachable;
    var server = try address.listen(server_io, .{});
    defer server.deinit(server_io);

    var state = State{};
    var accept_future = try Io.concurrent(server_io, Helper.acceptor, .{ server_io, &server, &state });
    var cancel_future = try Io.concurrent(server_io, Helper.canceler, .{ server_io, &accept_future });
    cancel_future.await(server_io);

    try std.testing.expect(state.accept_canceled);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "scheduler.cancel_deliver task=0") != null);
}

const GroupCancelState = struct {
    futex: u32 = 0,
    canceled_members: u8 = 0,
};

fn groupCancelMember(io: Io, state: *GroupCancelState) Io.Cancelable!void {
    io.futexWait(u32, &state.futex, 0) catch |err| {
        state.canceled_members += 1;
        return err;
    };
}

fn runGroupCancelTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var world = try World.init(task_world_allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var state = GroupCancelState{};
    var group: Io.Group = .init;
    try group.concurrent(io, groupCancelMember, .{ io, &state });
    try group.concurrent(io, groupCancelMember, .{ io, &state });

    // Park both members on the futex before canceling. The main-context
    // sleep drives the scheduler until only the timer remains.
    try Io.sleep(io, .fromNanoseconds(50), .awake);

    group.cancel(io);
    try std.testing.expectEqual(@as(u8, 2), state.canceled_members);

    return try allocator.dupe(u8, world.traceBytes());
}

test "io: group cancel delivers to parked members in deterministic order" {
    if (!fiber_supported) return error.SkipZigTest;

    const first = try runGroupCancelTrace(std.testing.allocator, 0x96C4);
    defer std.testing.allocator.free(first);
    const second = try runGroupCancelTrace(std.testing.allocator, 0x96C4);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    // Members are requested in ascending task order.
    const first_request = std.mem.indexOf(u8, first, "scheduler.cancel_request task=0").?;
    const second_request = std.mem.indexOf(u8, first, "scheduler.cancel_request task=1").?;
    try std.testing.expect(first_request < second_request);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.cancel_deliver task=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.cancel_deliver task=1") != null);
}

const GroupAwaitCancelState = struct {
    member_futex: u32 = 0,
    member_canceled: bool = false,
    await_canceled: bool = false,
    cancel_result_canceled: bool = false,
};

fn groupAwaitCancelMember(io: Io, state: *GroupAwaitCancelState) Io.Cancelable!void {
    io.futexWait(u32, &state.member_futex, 0) catch |err| {
        state.member_canceled = true;
        return err;
    };
}

fn groupAwaitCancelOuter(io: Io, state: *GroupAwaitCancelState) Io.Cancelable!void {
    var group: Io.Group = .init;
    group.concurrent(io, groupAwaitCancelMember, .{ io, state }) catch
        @panic("group member spawn failed");
    group.await(io) catch |err| {
        state.await_canceled = true;
        return err;
    };
}

fn groupAwaitCanceler(
    io: Io,
    future: *Io.Future(Io.Cancelable!void),
    state: *GroupAwaitCancelState,
) void {
    Io.sleep(io, .fromNanoseconds(50), .awake) catch unreachable;
    future.cancel(io) catch {
        state.cancel_result_canceled = true;
    };
}

test "io: canceling Group.await cancels members and resurfaces Canceled" {
    if (!fiber_supported) return error.SkipZigTest;

    var world = try World.init(task_world_allocator, .{ .seed = 0x96C5, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var state: GroupAwaitCancelState = .{};
    var outer = try Io.concurrent(io, groupAwaitCancelOuter, .{ io, &state });
    var canceler = try Io.concurrent(io, groupAwaitCanceler, .{ io, &outer, &state });
    canceler.await(io);

    try std.testing.expect(state.member_canceled);
    try std.testing.expect(state.await_canceled);
    try std.testing.expect(state.cancel_result_canceled);
}

test "io: cancel of a task without cancellation points runs it to completion" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn plain(value: u32) u32 {
            return value + 1;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xF11715, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var future = try Io.concurrent(io, Helper.plain, .{40});
    try std.testing.expectEqual(@as(u32, 41), future.cancel(io));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "scheduler.cancel_request task=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "scheduler.cancel_deliver") == null);
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

test "io: file metadata stays stable across table growth during disk latency" {
    if (!fiber_supported) return error.SkipZigTest;

    const Scenario = struct {
        io: Io,
        file: Io.File,
        started: u32 = 0,

        fn write(self: *@This()) void {
            self.started = 1;
            self.io.futexWake(u32, &self.started, std.math.maxInt(u32));
            self.file.writePositionalAll(self.io, "data", 0) catch @panic("write failed");
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xF11E, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{
        .disk = .{ .sector_size = 4, .min_latency_ns = 100 },
    });
    const io = sim.env.io();
    const backend = try world_module.internal.ioRuntime(sim).backendForNode(0);

    var file = try Io.Dir.cwd().createFile(io, "target", .{});
    defer file.close(io);
    try std.testing.expectEqual(@as(usize, 1), backend.files.items.len);
    try backend.files.shrinkAndFreePrecise(backend.allocator, backend.files.items.len);
    const table_before = backend.files.items.ptr;
    const target_meta = backend.files.items[0];

    var scenario: Scenario = .{ .io = io, .file = file };
    var writer = Io.async(io, Scenario.write, .{&scenario});
    while (scenario.started == 0) {
        io.futexWait(u32, &scenario.started, 0) catch unreachable;
    }

    _ = try backend.createFileMeta("growth-entry");
    try std.testing.expect(table_before != backend.files.items.ptr);
    try std.testing.expectEqual(target_meta, backend.files.items[0]);

    writer.await(io);
    try std.testing.expectEqual(@as(u64, 4), target_meta.len);
    try std.testing.expectEqual(@as(u64, 4), try file.length(io));
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

test "io: closed file handles retire backend state" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();
    const backend = try world_module.internal.ioRuntime(sim).backendForNode(0);

    var file = try Io.Dir.cwd().createFile(io, "retire-file.bin", .{ .read = true });
    try std.testing.expectEqual(@as(usize, 1), backend.handles.items.len);

    file.close(io);
    try std.testing.expectEqual(@as(usize, 0), backend.handles.items.len);
    try std.testing.expectError(error.AccessDenied, file.stat(io));
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
    try registerNoopProcess(sim, 0);
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
    try sim.restartProcess(0);

    // The crash killed the simulated process: the old handle is dead and the
    // file must be reopened, like a real restart.
    var read_out: [4]u8 = undefined;
    try std.testing.expectError(error.NotOpenForReading, file.readPositionalAll(io, &read_out, 0));

    var reopened = try Io.Dir.cwd().openFile(io, "pending.bin", .{ .mode = .read_only });
    defer reopened.close(io);
    try std.testing.expectEqual(@as(usize, 4), try reopened.readPositionalAll(io, &read_out, 0));
    try std.testing.expectEqualStrings("abcd", &read_out);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash_write") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "result=lost") != null);
}

test "io: file lengths re-derive from disk truth after a crash" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    try registerNoopProcess(sim, 0);
    const io = sim.env.io();

    var file = try Io.Dir.cwd().createFile(io, "length.bin", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "abcd", 0);
    try file.sync(io);

    // Extend the file with an unsynced write: the file layer's cached
    // length becomes 8 while only 4 bytes are durable.
    try file.writePositionalAll(io, "WXYZ", 4);
    try std.testing.expectEqual(@as(u64, 8), try file.length(io));
    const mtime_before_crash = (try Io.Dir.cwd().statFile(io, "length.bin", .{})).mtime;
    try std.testing.expect(mtime_before_crash.nanoseconds > 0);

    try sim.control.disk.setFaults(.{ .crash_lost_write_rate = .always() });
    try sim.control.disk.crash();
    try sim.control.disk.restart();
    try sim.restartProcess(0);

    // Before the crash-observer fix, the stale cached length (8) survived
    // the crash and reads exposed zero-filled phantom bytes.
    var reopened = try Io.Dir.cwd().openFile(io, "length.bin", .{ .mode = .read_only });
    defer reopened.close(io);
    try std.testing.expectEqual(@as(u64, 4), try reopened.length(io));
    const stat_after_crash = try Io.Dir.cwd().statFile(io, "length.bin", .{});
    try std.testing.expectEqual(@as(u64, 4), stat_after_crash.size);
    // Filesystem timestamps survive a machine crash; only lengths refresh.
    try std.testing.expectEqual(mtime_before_crash, stat_after_crash.mtime);

    var read_out: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try reopened.readPositionalAll(io, &read_out, 0));
    try std.testing.expectEqualStrings("abcd", read_out[0..4]);
}

test "io: crash rolls back unsynced deletion and preserves timestamps" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    try registerNoopProcess(sim, 0);
    const io = sim.env.io();

    {
        var file = try Io.Dir.cwd().createFile(io, "undelete.bin", .{});
        defer file.close(io);
        try file.writePositionalAll(io, "abcd", 0);
        try file.sync(io);
    }
    // Make the creation metadata durable so the crash only rolls back the
    // deletion below, not the file's existence.
    try sim.env.disk.syncDir(.{ .path = "." });
    const mtime_before = (try Io.Dir.cwd().statFile(io, "undelete.bin", .{})).mtime;
    try std.testing.expect(mtime_before.nanoseconds > 0);

    try Io.Dir.cwd().deleteFile(io, "undelete.bin");
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, "undelete.bin", .{}));

    try sim.control.disk.setFaults(.{ .crash_lost_metadata_rate = .always() });
    try sim.control.disk.crash();
    try sim.control.disk.restart();
    try sim.restartProcess(0);

    // The unsynced deletion was rolled back: the file is resurrected with
    // its durable contents and its pre-crash timestamp, not mtime zero.
    const stat = try Io.Dir.cwd().statFile(io, "undelete.bin", .{});
    try std.testing.expectEqual(@as(u64, 4), stat.size);
    try std.testing.expectEqual(mtime_before, stat.mtime);

    var reopened = try Io.Dir.cwd().openFile(io, "undelete.bin", .{ .mode = .read_only });
    defer reopened.close(io);
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try reopened.readPositionalAll(io, &buffer, 0));
    try std.testing.expectEqualStrings("abcd", &buffer);
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
    try cwd.createDir(io, "archive", .default_dir);
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

test "io: atomic replace preserves logical length across crash" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4096 } });
    try registerNoopProcess(sim, 0);
    const io = sim.env.io();
    const cwd = Io.Dir.cwd();

    var old = try cwd.createFile(io, "catalog.json", .{});
    try old.writeStreamingAll(io, "old");
    old.close(io);

    var replacement = try cwd.createFile(io, "catalog.json.tmp", .{});
    try replacement.writeStreamingAll(io, "[]");
    try replacement.sync(io);
    replacement.close(io);

    try cwd.rename("catalog.json.tmp", cwd, "catalog.json", io);
    try sim.env.disk.syncDir(.{ .path = "." });
    try sim.control.disk.crash();
    try sim.control.disk.restart();
    try sim.restartProcess(0);

    var reopened = try cwd.openFile(io, "catalog.json", .{ .mode = .read_only });
    defer reopened.close(io);
    try std.testing.expectEqual(@as(u64, 2), try reopened.length(io));
    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try reopened.readPositionalAll(io, &buffer, 0));
    try std.testing.expectEqualStrings("[]", &buffer);
}

test "io: failed multi-sector write leaves logical length unchanged" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1 });
    defer world.deinit();
    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4 } });
    const io = sim.env.io();

    var file = try Io.Dir.cwd().createFile(io, "multi-sector", .{});
    defer file.close(io);
    try sim.control.disk.setFaults(.{ .write_error_rate = .always() });
    try std.testing.expectError(error.InputOutput, file.writeStreamingAll(io, "abcdefgh"));
    try std.testing.expectEqual(
        @as(u64, 0),
        (try sim.env.disk.stat(.{ .path = "multi-sector" })).size,
    );
}

test "io: simulated directories support Ochi layout operations" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4096 } });
    const io = sim.env.io();

    try Io.Dir.createDirAbsolute(io, "/ochi", .default_dir);
    try Io.Dir.createDirAbsolute(io, "/ochi/partitions", .default_dir);
    try Io.Dir.accessAbsolute(io, "/ochi", .{});

    var ochi_dir = try Io.Dir.openDirAbsolute(io, "/ochi", .{ .iterate = true });
    defer ochi_dir.close(io);

    var lock_file = try ochi_dir.createFile(io, "lock", .{
        .read = true,
        .lock = .exclusive,
    });
    defer lock_file.close(io);

    const lock_stat = try ochi_dir.statFile(io, "lock", .{});
    try std.testing.expectEqual(Io.File.Kind.file, lock_stat.kind);
    const partitions_stat = try ochi_dir.statFile(io, "partitions", .{});
    try std.testing.expectEqual(Io.File.Kind.directory, partitions_stat.kind);

    var iterator = ochi_dir.iterate();
    var saw_lock = false;
    var saw_partitions = false;
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "lock")) {
            saw_lock = true;
            try std.testing.expectEqual(Io.File.Kind.file, entry.kind);
        } else if (std.mem.eql(u8, entry.name, "partitions")) {
            saw_partitions = true;
            try std.testing.expectEqual(Io.File.Kind.directory, entry.kind);
        } else {
            return error.UnexpectedDirectoryEntry;
        }
    }
    try std.testing.expect(saw_lock);
    try std.testing.expect(saw_partitions);

    var directory_file = try Io.Dir.openFileAbsolute(io, "/ochi", .{ .allow_directory = true });
    defer directory_file.close(io);
    try directory_file.sync(io);

    try std.testing.expect(std.mem.indexOf(
        u8,
        world.traceBytes(),
        "disk.sync_dir op=",
    ) != null);
}

test "io: simulated directory iteration returns direct children only" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();

    try Io.Dir.cwd().createDirPath(io, "root/nested");
    var nested_file = try Io.Dir.cwd().createFile(io, "root/nested/value", .{});
    nested_file.close(io);

    var root_dir = try Io.Dir.cwd().openDir(io, "root", .{ .iterate = true });
    defer root_dir.close(io);
    var iterator = root_dir.iterate();
    const entry = (try iterator.next(io)).?;
    try std.testing.expectEqualStrings("nested", entry.name);
    try std.testing.expectEqual(Io.File.Kind.directory, entry.kind);
    try std.testing.expectEqual(@as(?Io.Dir.Entry, null), try iterator.next(io));
}

test "io: directories are shared across processes and obey metadata durability" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    try registerNoopProcess(sim, 1);
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();

    try Io.Dir.cwd().createDir(node_zero_io, "shared", .default_dir);
    try Io.Dir.cwd().access(node_one_io, "shared", .{});

    try Io.Dir.cwd().createDir(node_zero_io, "ephemeral", .default_dir);
    try sim.control.disk.setFaults(.{ .crash_lost_metadata_rate = .always() });
    try sim.control.disk.crash();
    try sim.control.disk.restart();
    try sim.restartProcess(1);

    try std.testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().access(node_one_io, "ephemeral", .{}),
    );
}

test "io: directory iteration excludes crash-lost file metadata" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    try registerNoopProcess(sim, 0);
    const io = sim.env.io();

    try Io.Dir.cwd().createDir(io, "root", .default_dir);
    try sim.env.disk.syncDir(.{ .path = "." });
    var ghost = try Io.Dir.cwd().createFile(io, "root/ghost", .{});
    ghost.close(io);

    try sim.control.disk.setFaults(.{ .crash_lost_metadata_rate = .always() });
    try sim.control.disk.crash();
    try sim.control.disk.restart();
    try sim.restartProcess(0);

    var root = try Io.Dir.cwd().openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    var iterator = root.iterate();
    try std.testing.expectEqual(@as(?Io.Dir.Entry, null), try iterator.next(io));
}

test "io: file creation and rename enforce directory namespace invariants" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();
    const cwd = Io.Dir.cwd();

    try std.testing.expectError(
        error.FileNotFound,
        cwd.createFile(io, "missing/file", .{}),
    );

    var source = try cwd.createFile(io, "source", .{});
    source.close(io);
    try cwd.createDir(io, "destination", .default_dir);
    try std.testing.expectError(
        error.IsDir,
        cwd.rename("source", cwd, "destination", io),
    );
    try cwd.access(io, "source", .{});
    try cwd.access(io, "destination", .{});
}

test "io: pending empty file creation prevents directory creation at the same path" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();

    var file = try Io.Dir.cwd().createFile(node_zero_io, "catalog", .{});
    defer file.close(node_zero_io);

    try std.testing.expectError(
        error.PathAlreadyExists,
        Io.Dir.cwd().createDir(node_one_io, "catalog", .default_dir),
    );
}

test "io: createDirPath rejects an existing file at the target path" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();
    const cwd = Io.Dir.cwd();

    var file = try cwd.createFile(io, "leaf", .{});
    file.close(io);

    try std.testing.expectError(
        error.PathAlreadyExists,
        cwd.createDirPathStatus(io, "leaf", .default_dir),
    );
}

test "io: file stat and directory iteration report the same inode" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();
    const cwd = Io.Dir.cwd();

    var file = try cwd.createFile(io, "identity", .{});
    file.close(io);

    const stat = try cwd.statFile(io, "identity", .{});
    var dir = try cwd.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var saw_identity = false;
    while (try iterator.next(io)) |entry| {
        if (!std.mem.eql(u8, entry.name, "identity")) continue;
        saw_identity = true;
        try std.testing.expectEqual(Io.File.Kind.file, entry.kind);
        try std.testing.expectEqual(stat.inode, entry.inode);
    }
    try std.testing.expect(saw_identity);
}

test "io: pending file inode stays stable after another process discovers synced metadata" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();
    const cwd = Io.Dir.cwd();

    var file = try cwd.createFile(node_zero_io, "identity", .{});
    file.close(node_zero_io);
    const pending_stat = try cwd.statFile(node_zero_io, "identity", .{});

    try sim.env.disk.sync(.{ .path = "identity" });
    try sim.env.disk.syncDir(.{ .path = "." });

    const discovered_stat = try cwd.statFile(node_one_io, "identity", .{});
    try std.testing.expectEqual(pending_stat.inode, discovered_stat.inode);
}

test "io: atomic replace preserves unique live file inodes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();
    const cwd = Io.Dir.cwd();

    var replacement = try cwd.createFile(io, "catalog.tmp", .{});
    replacement.close(io);
    try cwd.rename("catalog.tmp", cwd, "catalog.json", io);

    var next_replacement = try cwd.createFile(io, "catalog.tmp", .{});
    next_replacement.close(io);

    const catalog_stat = try cwd.statFile(io, "catalog.json", .{});
    const tmp_stat = try cwd.statFile(io, "catalog.tmp", .{});
    try std.testing.expect(catalog_stat.inode != tmp_stat.inode);
}

test "io: world teardown releases outstanding file locks after scheduler teardown" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    errdefer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();

    const held = try Io.Dir.cwd().createFile(io, "lock", .{
        .lock = .exclusive,
    });
    _ = held;

    world.deinit();
}

test "io: simulated exclusive file locks release on close" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();
    const cwd = Io.Dir.cwd();

    var first = try cwd.createFile(io, "lock", .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    try first.writeStreamingAll(io, "data");
    try std.testing.expectError(error.WouldBlock, cwd.createFile(io, "lock", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    }));
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try first.readPositionalAll(io, &buffer, 0));
    try std.testing.expectEqualStrings("data", &buffer);
    first.close(io);

    var second = try cwd.openFile(io, "lock", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    second.close(io);
}

test "io: rename over an actively locked destination fails without panicking" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();
    const cwd = Io.Dir.cwd();

    var source = try cwd.createFile(node_zero_io, "source", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    defer source.close(node_zero_io);
    var dest = try cwd.createFile(node_one_io, "dest", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    defer dest.close(node_one_io);

    try std.testing.expectError(
        error.FileBusy,
        cwd.rename("source", cwd, "dest", node_zero_io),
    );
    try cwd.access(node_zero_io, "source", .{});
    try cwd.access(node_one_io, "dest", .{});
}

test "io: cross-process source lock holders release renamed lock path" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();
    const cwd = Io.Dir.cwd();

    var created = try cwd.createFile(node_zero_io, "shared", .{});
    created.close(node_zero_io);

    var shared = try cwd.openFile(node_one_io, "shared", .{
        .lock = .shared,
        .lock_nonblocking = true,
    });

    try cwd.rename("shared", cwd, "renamed", node_zero_io);
    shared.close(node_one_io);

    var renamed = try cwd.openFile(node_zero_io, "renamed", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    renamed.close(node_zero_io);
}

test "io: rename updates file metadata caches across processes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();
    const cwd = Io.Dir.cwd();

    var source = try cwd.createFile(node_zero_io, "source", .{ .read = true });
    try source.writePositionalAll(node_zero_io, "new!", 0);
    try source.sync(node_zero_io);
    source.close(node_zero_io);

    var dest = try cwd.createFile(node_one_io, "dest", .{ .read = true });
    defer dest.close(node_one_io);
    try dest.writePositionalAll(node_one_io, "old?", 0);
    try dest.sync(node_one_io);

    try cwd.access(node_one_io, "source", .{});
    var source_reader = try cwd.openFile(node_one_io, "source", .{ .mode = .read_only });
    defer source_reader.close(node_one_io);

    try cwd.rename("source", cwd, "dest", node_zero_io);

    try std.testing.expectError(error.FileNotFound, cwd.access(node_one_io, "source", .{}));
    try std.testing.expectError(error.AccessDenied, dest.length(node_one_io));

    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try source_reader.readPositionalAll(node_one_io, &buffer, 0));
    try std.testing.expectEqualStrings("new!", &buffer);

    var reopened = try cwd.openFile(node_one_io, "dest", .{ .mode = .read_only });
    defer reopened.close(node_one_io);
    try std.testing.expectEqual(@as(usize, 4), try reopened.readPositionalAll(node_one_io, &buffer, 0));
    try std.testing.expectEqualStrings("new!", &buffer);
}

test "io: delete invalidates file metadata caches across processes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();
    const cwd = Io.Dir.cwd();

    var file = try cwd.createFile(node_zero_io, "victim", .{ .read = true });
    try file.writePositionalAll(node_zero_io, "gone", 0);
    try file.sync(node_zero_io);
    file.close(node_zero_io);

    try cwd.access(node_one_io, "victim", .{});
    var reader = try cwd.openFile(node_one_io, "victim", .{ .mode = .read_only });
    defer reader.close(node_one_io);

    try cwd.deleteFile(node_zero_io, "victim");

    try std.testing.expectError(error.FileNotFound, cwd.access(node_one_io, "victim", .{}));
    try std.testing.expectError(error.AccessDenied, reader.length(node_one_io));
}

test "io: rename preserves source and destination lock waiters" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn waitOpen(io: Io, path: []const u8, started: *u32, acquired: *u32) void {
            started.* = 1;
            io.futexWake(u32, started, std.math.maxInt(u32));
            var file = Io.Dir.cwd().openFile(io, path, .{
                .lock = .exclusive,
                .lock_nonblocking = false,
            }) catch @panic("lock wait failed");
            acquired.* = 1;
            io.futexWake(u32, acquired, std.math.maxInt(u32));
            file.close(io);
        }

        fn waitSource(io: Io, started: *u32, acquired: *u32) void {
            waitOpen(io, "source", started, acquired);
        }

        fn waitDest(io: Io, started: *u32, acquired: *u32) void {
            waitOpen(io, "dest", started, acquired);
        }

        fn renameSourceToDest(io: Io, started: *u32) void {
            started.* = 1;
            io.futexWake(u32, started, std.math.maxInt(u32));
            Io.Dir.cwd().rename("source", Io.Dir.cwd(), "dest", io) catch @panic("rename failed");
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{
        .disk = .{ .min_latency_ns = 100 },
        .network = .{ .nodes = 2 },
    });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();
    const cwd = Io.Dir.cwd();

    var source_holder = try cwd.createFile(node_zero_io, "source", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    var dest = try cwd.createFile(node_zero_io, "dest", .{});
    dest.close(node_zero_io);

    var source_started: u32 = 0;
    var source_acquired: u32 = 0;
    var source_future = Io.async(node_one_io, Helper.waitSource, .{ node_one_io, &source_started, &source_acquired });
    while (source_started == 0) {
        node_one_io.futexWait(u32, &source_started, 0) catch unreachable;
    }

    var rename_started: u32 = 0;
    var rename_future = Io.async(node_zero_io, Helper.renameSourceToDest, .{ node_zero_io, &rename_started });
    while (rename_started == 0) {
        node_zero_io.futexWait(u32, &rename_started, 0) catch unreachable;
    }
    try sim.control.runFor(10);

    var dest_started: u32 = 0;
    var dest_acquired: u32 = 0;
    var dest_future = Io.async(node_one_io, Helper.waitDest, .{ node_one_io, &dest_started, &dest_acquired });
    while (dest_started == 0) {
        node_one_io.futexWait(u32, &dest_started, 0) catch unreachable;
    }
    try sim.control.runFor(10);
    try std.testing.expectEqual(@as(u32, 0), dest_acquired);

    try sim.control.runFor(90);
    rename_future.await(node_zero_io);

    source_holder.close(node_zero_io);
    source_future.await(node_one_io);
    dest_future.await(node_one_io);

    try std.testing.expectEqual(@as(u32, 1), source_acquired);
    try std.testing.expectEqual(@as(u32, 1), dest_acquired);
}

test "io: rename reserves destination lock across disk latency" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn renameOverDest(io: Io, started: *u32) void {
            started.* = 1;
            io.futexWake(u32, started, std.math.maxInt(u32));
            Io.Dir.cwd().rename("source", Io.Dir.cwd(), "dest", io) catch @panic("rename failed");
        }

        fn lockDest(io: Io, started: *u32, acquired: *u32) void {
            started.* = 1;
            io.futexWake(u32, started, std.math.maxInt(u32));
            var file = Io.Dir.cwd().openFile(io, "dest", .{
                .lock = .exclusive,
                .lock_nonblocking = false,
            }) catch @panic("lock failed");
            acquired.* = 1;
            io.futexWake(u32, acquired, std.math.maxInt(u32));
            file.close(io);
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{
        .disk = .{ .min_latency_ns = 100 },
        .network = .{ .nodes = 2 },
    });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();
    const cwd = Io.Dir.cwd();

    var source = try cwd.createFile(node_zero_io, "source", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    var dest = try cwd.createFile(node_zero_io, "dest", .{});
    dest.close(node_zero_io);

    var rename_started: u32 = 0;
    var rename_future = Io.async(node_zero_io, Helper.renameOverDest, .{ node_zero_io, &rename_started });
    while (rename_started == 0) {
        node_zero_io.futexWait(u32, &rename_started, 0) catch unreachable;
    }
    try sim.control.runFor(10);

    var lock_started: u32 = 0;
    var lock_acquired: u32 = 0;
    var lock_future = Io.async(node_one_io, Helper.lockDest, .{ node_one_io, &lock_started, &lock_acquired });
    while (lock_started == 0) {
        node_one_io.futexWait(u32, &lock_started, 0) catch unreachable;
    }
    try sim.control.runFor(10);
    try std.testing.expectEqual(@as(u32, 0), lock_acquired);

    try sim.control.runFor(80);
    rename_future.await(node_zero_io);
    try std.testing.expectEqual(@as(u32, 0), lock_acquired);

    source.close(node_zero_io);
    lock_future.await(node_one_io);
    try std.testing.expectEqual(@as(u32, 1), lock_acquired);
}

test "io: file locks follow file rename" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();
    const cwd = Io.Dir.cwd();

    var holder = try cwd.createFile(node_zero_io, "locked", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    try cwd.rename("locked", cwd, "renamed", node_zero_io);

    try std.testing.expectError(error.WouldBlock, cwd.openFile(node_one_io, "renamed", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    }));

    holder.close(node_zero_io);
    var reopened = try cwd.openFile(node_one_io, "renamed", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    reopened.close(node_one_io);
}

test "io: file locks coordinate processes and blocking acquisition waits" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn closeAfter(io: Io, file: Io.File) void {
            Io.sleep(io, .fromNanoseconds(10), .awake) catch unreachable;
            file.close(io);
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();
    const cwd = Io.Dir.cwd();

    const first = try cwd.createFile(node_zero_io, "lock", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    try std.testing.expectError(error.WouldBlock, cwd.openFile(node_one_io, "lock", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    }));

    var close_future = Io.async(node_zero_io, Helper.closeAfter, .{ node_zero_io, first });
    var second = try cwd.openFile(node_one_io, "lock", .{
        .lock = .exclusive,
        .lock_nonblocking = false,
    });
    second.close(node_one_io);
    close_future.await(node_zero_io);
}

test "io: process kill retires blocked file lock waiters" {
    if (!fiber_supported) return error.SkipZigTest;

    const Helper = struct {
        fn waitForLock(io: Io, started: *u32) void {
            started.* = 1;
            io.futexWake(u32, started, std.math.maxInt(u32));
            var file = Io.Dir.cwd().openFile(io, "lock", .{
                .lock = .exclusive,
                .lock_nonblocking = false,
            }) catch @panic("blocking lock failed");
            file.close(io);
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const node_zero_io = (try sim.envForNode(0)).io();
    const node_one_io = (try sim.envForNode(1)).io();

    var holder = try Io.Dir.cwd().createFile(node_zero_io, "lock", .{
        .lock = .exclusive,
    });
    var started: u32 = 0;
    var waiter = Io.async(node_one_io, Helper.waitForLock, .{ node_one_io, &started });
    while (started == 0) {
        node_one_io.futexWait(u32, &started, 0) catch unreachable;
    }
    try std.testing.expectError(error.Deadlock, sim.control.runTasksUntilIdle());
    try std.testing.expectEqual(@as(usize, 1), sim.control.blockedTaskCount());

    try sim.killProcess(1);
    waiter.await(node_zero_io);
    holder.close(node_zero_io);
    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
}

test "io: logical path validation matches simulated and real disks" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real = try disk_module.RealDisk.init(tmp.dir, std.testing.io, .{});
    defer real.deinit();

    try sim.env.disk.write(.{ .path = "sim/valid.log", .offset = 0, .bytes = &.{} });
    try real.disk().write(.{ .path = "real/valid.log", .offset = 0, .bytes = &.{} });
    try Io.Dir.cwd().createDir(sim.env.io(), "io", .default_dir);
    var valid_file = try Io.Dir.cwd().createFile(sim.env.io(), "io/valid.log", .{});
    valid_file.close(sim.env.io());
    try sim.env.disk.syncDir(.{ .path = "." });
    try std.testing.expectError(
        error.DirectorySyncUnsupported,
        real.disk().syncDir(.{ .path = "." }),
    );

    const invalid_paths = [_][]const u8{
        "",
        ".",
        "..",
        "archive/./wal.log",
        "archive/../wal.log",
        "archive//wal.log",
        "archive/wal.log/",
        "/wal.log",
        "C:/wal.log",
        "archive\\wal.log",
        "wal\x00.log",
    };
    for (invalid_paths) |path| {
        try std.testing.expectError(
            error.InvalidPath,
            sim.env.disk.write(.{ .path = path, .offset = 0, .bytes = &.{} }),
        );
        try std.testing.expectError(
            error.InvalidPath,
            real.disk().write(.{ .path = path, .offset = 0, .bytes = &.{} }),
        );
        if (std.mem.eql(u8, path, "/wal.log")) continue;
        try std.testing.expectError(
            error.FileNotFound,
            Io.Dir.cwd().createFile(sim.env.io(), path, .{}),
        );
    }

    var absolute_file = try Io.Dir.createFileAbsolute(sim.env.io(), "/wal.log", .{});
    absolute_file.close(sim.env.io());
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

test "io: closed sockets retire backend state" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var backend = testIo(&world);
    defer backend.deinit();
    const io = backend.io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 1244) catch unreachable;
    var server = try address.listen(io, .{});
    try std.testing.expectEqual(@as(usize, 1), backend.handles.items.len);

    const client = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    const accepted = try server.accept(io);
    try std.testing.expectEqual(@as(usize, 3), backend.handles.items.len);

    client.close(io);
    try std.testing.expectEqual(@as(usize, 2), backend.handles.items.len);
    try std.testing.expectError(error.SocketUnconnected, io.vtable.netWrite(io.userdata, client.socket.handle, "", &.{""}, 1));

    accepted.close(io);
    try std.testing.expectEqual(@as(usize, 1), backend.handles.items.len);

    server.deinit(io);
    try std.testing.expectEqual(@as(usize, 0), backend.handles.items.len);
    try std.testing.expectError(error.SocketNotListening, server.accept(io));
}

test "io: closing listener retires pending unaccepted connections" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var backend = testIo(&world);
    defer backend.deinit();
    const io = backend.io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 1245) catch unreachable;
    var server = try address.listen(io, .{});
    const client = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    try std.testing.expectEqual(@as(usize, 3), backend.handles.items.len);

    server.deinit(io);
    try std.testing.expectEqual(@as(usize, 1), backend.handles.items.len);
    try std.testing.expectError(error.SocketNotListening, server.accept(io));

    const chunk: [1][]const u8 = .{"ping"};
    try std.testing.expectError(
        error.ConnectionResetByPeer,
        io.vtable.netWrite(io.userdata, client.socket.handle, "", &chunk, 1),
    );

    var buffer: [4]u8 = undefined;
    var read_buffers: [1][]u8 = .{&buffer};
    try std.testing.expectError(
        error.ConnectionResetByPeer,
        io.vtable.netRead(io.userdata, client.socket.handle, &read_buffers),
    );

    client.close(io);
    try std.testing.expectEqual(@as(usize, 0), backend.handles.items.len);
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

const SimHttpServerTask = struct {
    server: *Io.net.Server,
    io: Io,
    served: bool = false,

    fn run(self: *SimHttpServerTask) void {
        self.serve() catch |err| std.debug.panic("simulated http server failed: {}", .{err});
        self.served = true;
    }

    fn serve(self: *SimHttpServerTask) !void {
        const stream = try self.server.accept(self.io);
        defer stream.close(self.io);

        var in_buffer: [4096]u8 = undefined;
        var out_buffer: [1024]u8 = undefined;
        var stream_reader = stream.reader(self.io, &in_buffer);
        var stream_writer = stream.writer(self.io, &out_buffer);

        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = try http_server.receiveHead();
        try request.respond(sim_http_body, .{});
    }
};

const sim_http_body = "hello from simulated std.http\n";

fn fetchSimHttp(
    client_io: Io,
    url: []const u8,
    body_buffer: []u8,
) !usize {
    var client = std.http.Client{
        .allocator = std.testing.allocator,
        .io = client_io,
    };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var request = try client.request(.GET, uri, .{});
    defer request.deinit();
    try request.sendBodiless();

    var redirect_buffer: [1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    try std.testing.expectEqual(std.http.Status.ok, response.head.status);

    var transfer_buffer: [1024]u8 = undefined;
    var body_reader = response.reader(&transfer_buffer);
    return try body_reader.readSliceShort(body_buffer);
}

test "io: unmodified std.http.Client fetches an IPv4 literal URL under simulation" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xD05, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{
        .network = .{ .nodes = 2, .path_capacity = 8 },
        .task_stack_size = 8 * 1024 * 1024,
    });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 8080) catch unreachable;
    var server = try address.listen(server_io, .{});
    defer server.deinit(server_io);

    var server_task = SimHttpServerTask{ .server = &server, .io = server_io };
    var server_future = try Io.concurrent(server_io, SimHttpServerTask.run, .{&server_task});

    var body_buffer: [256]u8 = undefined;
    const body_len = try fetchSimHttp(client_io, "http://127.0.0.1:8080/", &body_buffer);

    server_future.await(server_io);
    try std.testing.expect(server_task.served);
    try std.testing.expectEqualStrings(sim_http_body, body_buffer[0..body_len]);
    try std.testing.expect(std.mem.indexOf(
        u8,
        world.traceBytes(),
        "io.net.lookup host=127.0.0.1 port=8080 results=1",
    ) != null);
}

test "io: std.http.Client localhost URL races loopback candidates and v4 wins" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xD06, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{
        .network = .{ .nodes = 2, .path_capacity = 8 },
        .task_stack_size = 8 * 1024 * 1024,
    });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 8081) catch unreachable;
    var server = try address.listen(server_io, .{});
    defer server.deinit(server_io);

    var server_task = SimHttpServerTask{ .server = &server, .io = server_io };
    var server_future = try Io.concurrent(server_io, SimHttpServerTask.run, .{&server_task});

    // `localhost` resolves to [::1, 127.0.0.1]; `connectMany` races both
    // through the cancellation machinery. The v6 attempt finds no simulated
    // listener and fails cleanly, the v4 attempt wins.
    var body_buffer: [256]u8 = undefined;
    const body_len = try fetchSimHttp(client_io, "http://localhost:8081/", &body_buffer);

    server_future.await(server_io);
    try std.testing.expect(server_task.served);
    try std.testing.expectEqualStrings(sim_http_body, body_buffer[0..body_len]);
    try std.testing.expect(std.mem.indexOf(
        u8,
        world.traceBytes(),
        "io.net.lookup host=localhost port=8081 results=",
    ) != null);
}

test "io: netLookup rejects non-literal host names as unknown" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xD07, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 1 } });
    const client_io = (try sim.envForNode(0)).io();

    // Real DNS, /etc/hosts, and search domains are host state and stay
    // unsupported under simulation: any non-literal name is unknown.
    const host = try Io.net.HostName.init("registry.example");
    try std.testing.expectError(
        error.UnknownHostName,
        host.connect(client_io, 80, .{ .mode = .stream }),
    );
}

fn simHttpFetchTrace(seed: u64) ![]u8 {
    var world = try World.init(task_world_allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{
        .network = .{ .nodes = 2, .path_capacity = 8 },
        .task_stack_size = 8 * 1024 * 1024,
    });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 8080) catch unreachable;
    var server = try address.listen(server_io, .{});
    defer server.deinit(server_io);

    var server_task = SimHttpServerTask{ .server = &server, .io = server_io };
    var server_future = try Io.concurrent(server_io, SimHttpServerTask.run, .{&server_task});

    var body_buffer: [256]u8 = undefined;
    _ = try fetchSimHttp(client_io, "http://127.0.0.1:8080/", &body_buffer);
    server_future.await(server_io);

    return try std.testing.allocator.dupe(u8, world.traceBytes());
}

test "io: std.http.Client fetch replays byte-identically from the same seed" {
    const first = try simHttpFetchTrace(0xD05);
    defer std.testing.allocator.free(first);
    const second = try simHttpFetchTrace(0xD05);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "io: transitionToLiveness restores the core and leaves non-core failures permanent" {
    const State = struct {
        starts: u32 = 0,
        kills: u32 = 0,

        fn onKill(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.kills += 1;
        }

        fn restart(raw: *anyopaque, _: env_module.Env) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.starts += 1;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA70, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 3 } });

    var states: [3]State = .{ .{}, .{}, .{} };
    for (&states, 0..) |*state, node| {
        try sim.registerProcess(@intCast(node), .{
            .ptr = state,
            .on_kill = State.onKill,
            .restart = State.restart,
        });
        try sim.control.process.setDynamics(@intCast(node), .{
            .crash_rate = .percent(50),
            .restart_rate = .percent(50),
        });
    }
    try sim.control.network.setLossiness(.{ .drop_rate = .percent(50) });
    try sim.control.network.setClogs(.{ .path_clog_rate = .percent(10), .path_clog_duration_ns = 100 });
    try sim.control.network.setPartitionDynamics(.{ .partition_rate = .percent(10), .unpartition_rate = .percent(10) });
    try sim.control.disk.setFaults(.{ .read_error_rate = .percent(10) });
    try sim.control.allocation.setFaults(.{ .buggify_rate = .percent(10) });

    try sim.killProcess(0);
    try sim.killProcess(2);
    try sim.control.network.partition(&.{0}, &.{ 1, 2 });
    try sim.control.network.setNode(0, false);
    try sim.control.network.clog(1, 0, 1_000);

    try sim.transitionToLiveness(&.{ 0, 1 });

    // The killed core process restarts once; the alive core process keeps
    // its incarnation and the killed non-core process stays down.
    try std.testing.expectEqual(@as(u32, 1), states[0].starts);
    try std.testing.expectEqual(@as(u32, 0), states[1].starts);
    try std.testing.expectEqual(@as(u32, 0), states[1].kills);
    try std.testing.expectEqual(@as(u32, 0), states[2].starts);

    const trace = world.traceBytes();
    try std.testing.expect(std.mem.indexOf(u8, trace, "liveness.transition core_count=2") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        trace,
        "network.liveness_restore core_count=2 restored_links=2 cleared_clogs=1 revived_nodes=1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "process.restart node=0 automatic=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "process.dynamics node=2 crash_rate=0/1 restart_rate=0/1") != null);
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(trace, "process.restart node=2"));

    // With every probabilistic rate zeroed, a long run schedules no new
    // automatic faults and never revives the non-core process.
    try sim.control.runFor(100_000);
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(world.traceBytes(), "reason=auto_crash"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(world.traceBytes(), "automatic=true"));
    try std.testing.expectEqual(@as(u32, 0), states[2].starts);
}

test "io: transitionToLiveness clears an automatic partition inside the core" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xA71, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    try sim.control.network.setPartitionDynamics(.{
        .partition_rate = .always(),
        .unpartition_rate = .never(),
    });
    try sim.control.runFor(20);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(world.traceBytes(), "network.auto_partition"));

    try sim.transitionToLiveness(&.{ 0, 1 });

    try std.testing.expect(std.mem.indexOf(
        u8,
        world.traceBytes(),
        "network.liveness_restore core_count=2 restored_links=2 cleared_clogs=0 revived_nodes=0",
    ) != null);

    try sim.control.runFor(1_000);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(world.traceBytes(), "network.auto_partition"));
}

test "io: transitionToLiveness restarts a crashed disk before reviving core processes" {
    const State = struct {
        starts: u32 = 0,
        kills: u32 = 0,

        fn onKill(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.kills += 1;
        }

        fn restart(raw: *anyopaque, _: env_module.Env) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.starts += 1;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA72, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    var state: State = .{};
    try sim.registerProcess(0, .{
        .ptr = &state,
        .on_kill = State.onKill,
        .restart = State.restart,
    });

    try sim.control.disk.crash();
    try std.testing.expectEqual(@as(u32, 1), state.kills);

    try sim.transitionToLiveness(&.{0});

    try std.testing.expectEqual(@as(u32, 1), state.starts);
    const trace = world.traceBytes();
    try std.testing.expect(std.mem.indexOf(u8, trace, "disk.restart status=ok") != null);
    // No network is configured, so the transition touches no network state.
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(trace, "network.liveness_restore"));
}

test "io: transitionToLiveness preflight failures leave the transition retryable" {
    const State = struct {
        starts: u32 = 0,

        fn restart(raw: *anyopaque, _: env_module.Env) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.starts += 1;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA73, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    var state: State = .{};
    try sim.registerProcess(0, .{ .ptr = &state, .restart = State.restart });
    try sim.killProcess(0);
    try sim.killProcess(1);

    try std.testing.expectError(error.InvalidNode, sim.transitionToLiveness(&.{ 0, 7 }));
    try std.testing.expectError(error.ProcessNotRegistered, sim.transitionToLiveness(&.{ 0, 1 }));
    // The failed calls consumed nothing and mutated no fault state.
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(world.traceBytes(), "liveness.transition"));
    try std.testing.expectEqual(@as(u32, 0), state.starts);

    // Correcting the core lets the one-shot transition proceed.
    try sim.transitionToLiveness(&.{0});
    try std.testing.expectEqual(@as(u32, 1), state.starts);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(world.traceBytes(), "liveness.transition core_count=1"));
}

test "io: transitionToLiveness remains retryable after lifecycle failure" {
    const State = struct {
        attempts: u32 = 0,
        starts: u32 = 0,

        fn restart(raw: *anyopaque, _: env_module.Env) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.attempts += 1;
            if (self.attempts == 1) return error.RestartFailed;
            self.starts += 1;
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xA74, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    var state: State = .{};
    try sim.registerProcess(0, .{ .ptr = &state, .restart = State.restart });
    try sim.killProcess(0);

    try std.testing.expectError(error.RestartFailed, sim.transitionToLiveness(&.{0}));
    try std.testing.expectEqual(@as(u32, 1), state.attempts);
    try std.testing.expectEqual(@as(u32, 0), state.starts);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(world.traceBytes(), "liveness.transition core_count=1"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(world.traceBytes(), "process.restart node=0"));

    try sim.transitionToLiveness(&.{0});
    try std.testing.expectEqual(@as(u32, 2), state.attempts);
    try std.testing.expectEqual(@as(u32, 1), state.starts);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(world.traceBytes(), "liveness.transition core_count=1"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(world.traceBytes(), "process.restart node=0 automatic=false"));
}

const StartRace = struct {
    server_io: Io,
    client_io: Io,
    connected: bool = false,
    connect_error: ?anyerror = null,

    fn serverTask(self: *StartRace) void {
        const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4710) catch unreachable;
        var listener = address.listen(self.server_io, .{}) catch |err| {
            std.debug.panic("start race listen failed: {}", .{err});
        };
        defer listener.deinit(self.server_io);
        if (listener.accept(self.server_io)) |stream| {
            stream.close(self.server_io);
        } else |_| {}
    }

    fn clientTask(self: *StartRace) void {
        // The suspension point before connect is the structural mask: with
        // no start jitter, virtual time only advances once the server has
        // also blocked, which is after `listen` registered the listener,
        // so the server wins this race on every seed.
        Io.sleep(self.client_io, .fromNanoseconds(10), .awake) catch
            @panic("start race client sleep failed");
        const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4710) catch unreachable;
        if (address.connect(self.client_io, .{ .mode = .stream, .protocol = .tcp })) |stream| {
            self.connected = true;
            stream.close(self.client_io);
        } else |err| {
            self.connect_error = err;
        }
    }
};

const StartRaceOutcome = struct {
    connected: bool,
    connect_error: ?anyerror,
    trace: []u8,
};

/// A server task with no suspension point before `listen` races a client
/// task that connects immediately. Without start jitter the spawn order
/// decides the race identically on every seed; with jitter the seed does.
fn runStartRace(allocator: std.mem.Allocator, seed: u64, jitter_ns: u64) !StartRaceOutcome {
    var world = try World.init(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{
        .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 8 },
        .task_start_jitter_ns = jitter_ns,
    });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });

    var race = StartRace{ .server_io = server_io, .client_io = client_io };
    var server_future = try Io.concurrent(server_io, StartRace.serverTask, .{&race});
    var client_future = try Io.concurrent(client_io, StartRace.clientTask, .{&race});

    client_future.await(client_io);
    // A refused client leaves the server parked in accept; cancellation is
    // the shutdown path either way.
    server_future.cancel(server_io);
    if (sim.control.blockedTaskCount() != 0) return error.ScenarioDeadlocked;

    return .{
        .connected = race.connected,
        .connect_error = race.connect_error,
        .trace = try allocator.dupe(u8, world.traceBytes()),
    };
}

test "io: task start jitter defaults off and masks the connect-before-listen race" {
    var seed: u64 = 0;
    while (seed < 8) : (seed += 1) {
        const outcome = try runStartRace(std.testing.allocator, seed, 0);
        defer std.testing.allocator.free(outcome.trace);

        // The mask holds on every seed: the client's sleep parks it, time
        // advances only after the server blocks in accept (listener
        // registered), and the connect always succeeds. No seed can find
        // the connect-before-listen ordering.
        try std.testing.expect(outcome.connected);
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, outcome.trace, "scheduler.start_jitter"));
    }
}

test "io: task start jitter reproduces a connect-before-listen race with same-seed replay" {
    const jitter_ns = 1000;
    var refused_seed: ?u64 = null;
    var success_seen = false;

    var seed: u64 = 0;
    while (seed < 32) : (seed += 1) {
        const outcome = try runStartRace(std.testing.allocator, seed, jitter_ns);
        defer std.testing.allocator.free(outcome.trace);

        try std.testing.expect(std.mem.indexOf(u8, outcome.trace, "scheduler.start_jitter") != null);
        if (outcome.connected) {
            success_seen = true;
        } else {
            try std.testing.expectEqual(@as(anyerror, error.ConnectionRefused), outcome.connect_error.?);
            if (refused_seed == null) refused_seed = seed;
        }
        if (success_seen and refused_seed != null) break;
    }

    // The jittered schedule space must contain both orderings.
    try std.testing.expect(success_seen);
    try std.testing.expect(refused_seed != null);

    // The found race replays byte-identically from its seed.
    const first = try runStartRace(std.testing.allocator, refused_seed.?, jitter_ns);
    defer std.testing.allocator.free(first.trace);
    const second = try runStartRace(std.testing.allocator, refused_seed.?, jitter_ns);
    defer std.testing.allocator.free(second.trace);

    try std.testing.expect(!first.connected);
    try std.testing.expectEqualStrings(first.trace, second.trace);
}

const QueueBackpressure = struct {
    server_io: Io,
    client_io: Io,
    received: [96 * 1024]u8 = undefined,
    received_len: usize = 0,

    fn serverTask(self: *QueueBackpressure) void {
        const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4720) catch unreachable;
        var listener = address.listen(self.server_io, .{}) catch |err| {
            std.debug.panic("backpressure listen failed: {}", .{err});
        };
        defer listener.deinit(self.server_io);
        const stream = listener.accept(self.server_io) catch |err| {
            std.debug.panic("backpressure accept failed: {}", .{err});
        };
        defer stream.close(self.server_io);

        while (self.received_len < self.received.len) {
            var bufs: [1][]u8 = .{self.received[self.received_len..]};
            const read = self.server_io.vtable.netRead(
                self.server_io.userdata,
                stream.socket.handle,
                &bufs,
            ) catch |err| {
                std.debug.panic("backpressure read failed: {}", .{err});
            };
            if (read == 0) break;
            self.received_len += read;
        }
    }

    fn clientTask(self: *QueueBackpressure) void {
        Io.sleep(self.client_io, .fromNanoseconds(10), .awake) catch
            @panic("backpressure client sleep failed");
        const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4720) catch unreachable;
        const stream = address.connect(self.client_io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
            std.debug.panic("backpressure connect failed: {}", .{err});
        };
        defer stream.close(self.client_io);

        var payload: [96 * 1024]u8 = undefined;
        for (&payload, 0..) |*byte, index| {
            byte.* = @truncate(index *% 13 +% 5);
        }
        var written: usize = 0;
        while (written < payload.len) {
            const chunk: [1][]const u8 = .{payload[written..]};
            written += self.client_io.vtable.netWrite(
                self.client_io.userdata,
                stream.socket.handle,
                "",
                &chunk,
                1,
            ) catch |err| {
                std.debug.panic("backpressure write failed: {}", .{err});
            };
        }
    }
};

test "io: stream writes larger than the path queue backpressure instead of failing" {
    var world = try World.init(std.testing.allocator, .{ .seed = 0xBACC, .tick_ns = 10 });
    defer world.deinit();

    // A 96 KiB write becomes six 16 KiB segments, far beyond a two-slot
    // path queue: without write backpressure this fails EventQueueFull;
    // with it, the writer parks until the reader drains.
    const sim = try world.simulate(.{
        .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 2 },
    });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });

    var scenario = QueueBackpressure{ .server_io = server_io, .client_io = client_io };
    var server_future = try Io.concurrent(server_io, QueueBackpressure.serverTask, .{&scenario});
    var client_future = try Io.concurrent(client_io, QueueBackpressure.clientTask, .{&scenario});

    client_future.await(client_io);
    server_future.await(server_io);
    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());

    try std.testing.expectEqual(scenario.received.len, scenario.received_len);
    for (scenario.received, 0..) |byte, index| {
        try std.testing.expectEqual(@as(u8, @truncate(index *% 13 +% 5)), byte);
    }
}

/// A writer parked on shared stream backpressure waits on the world-global
/// key, so connection teardown must wake that key too; waking only the
/// per-handle keys leaves the writer parked forever.
const BackpressureTeardown = struct {
    sim: World.Simulation,
    server_io: Io,
    client_io: Io,
    kill_server_process: bool,
    write_error: ?anyerror = null,

    fn serverTask(self: *BackpressureTeardown) void {
        const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4721) catch unreachable;
        var listener = address.listen(self.server_io, .{}) catch |err| {
            std.debug.panic("teardown listen failed: {}", .{err});
        };
        defer listener.deinit(self.server_io);
        const stream = listener.accept(self.server_io) catch |err| {
            std.debug.panic("teardown accept failed: {}", .{err});
        };
        // Never read: the shared path queue stays full, so the writer
        // stays parked until this endpoint is torn down. The sleeps give
        // the writer time to fill the queue and park.
        if (self.kill_server_process) {
            // Park far past the kill; the process kill sweeps the stream
            // and this task, so nothing after the sleep runs.
            Io.sleep(self.server_io, .fromNanoseconds(1_000_000), .awake) catch {};
            return;
        }
        Io.sleep(self.server_io, .fromNanoseconds(1000), .awake) catch
            @panic("teardown server sleep failed");
        stream.close(self.server_io);
    }

    fn killerTask(self: *BackpressureTeardown) void {
        if (!self.kill_server_process) return;
        Io.sleep(self.client_io, .fromNanoseconds(2000), .awake) catch
            @panic("teardown killer sleep failed");
        self.sim.killProcess(0) catch @panic("teardown process kill failed");
    }

    fn clientTask(self: *BackpressureTeardown) void {
        Io.sleep(self.client_io, .fromNanoseconds(10), .awake) catch
            @panic("teardown client sleep failed");
        const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4721) catch unreachable;
        const stream = address.connect(self.client_io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
            std.debug.panic("teardown connect failed: {}", .{err});
        };
        defer stream.close(self.client_io);

        var payload: [96 * 1024]u8 = undefined;
        for (&payload, 0..) |*byte, index| {
            byte.* = @truncate(index *% 13 +% 5);
        }
        var written: usize = 0;
        while (written < payload.len) {
            const chunk: [1][]const u8 = .{payload[written..]};
            written += self.client_io.vtable.netWrite(
                self.client_io.userdata,
                stream.socket.handle,
                "",
                &chunk,
                1,
            ) catch |err| {
                self.write_error = err;
                return;
            };
        }
    }

    fn run(kill_server_process: bool) !?anyerror {
        var world = try World.init(std.testing.allocator, .{ .seed = 0xBACD, .tick_ns = 10 });
        defer world.deinit();

        const sim = try world.simulate(.{
            .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 2 },
        });
        const server_io = (try sim.envForNode(0)).io();
        const client_io = (try sim.envForNode(1)).io();
        try sim.control.network.setLatency(.{ .min_latency_ns = 30 });

        var scenario = BackpressureTeardown{
            .sim = sim,
            .server_io = server_io,
            .client_io = client_io,
            .kill_server_process = kill_server_process,
        };
        var server_future = try Io.concurrent(server_io, BackpressureTeardown.serverTask, .{&scenario});
        var client_future = try Io.concurrent(client_io, BackpressureTeardown.clientTask, .{&scenario});
        var killer_future = try Io.concurrent(client_io, BackpressureTeardown.killerTask, .{&scenario});

        client_future.await(client_io);
        server_future.await(server_io);
        killer_future.await(client_io);
        try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
        return scenario.write_error;
    }
};

test "io: peer close wakes a writer parked on stream backpressure" {
    const write_error = try BackpressureTeardown.run(false);
    try std.testing.expectEqual(@as(anyerror, error.ConnectionResetByPeer), write_error.?);
}

test "io: process kill wakes a writer parked on stream backpressure" {
    const write_error = try BackpressureTeardown.run(true);
    try std.testing.expectEqual(@as(anyerror, error.ConnectionResetByPeer), write_error.?);
}

test "io: closing a connection reclaims its queued stream frames" {
    if (!fiber_supported) return error.SkipZigTest;

    const Scenario = struct {
        server_io: Io,
        client_io: Io,
        sent: u32 = 0,

        fn serverTask(self: *@This()) void {
            const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4722) catch unreachable;
            var listener = address.listen(self.server_io, .{}) catch @panic("listen failed");
            defer listener.deinit(self.server_io);
            const stream = listener.accept(self.server_io) catch @panic("accept failed");
            defer stream.close(self.server_io);

            while (self.sent == 0) {
                self.server_io.futexWait(u32, &self.sent, 0) catch @panic("wait failed");
            }
        }

        fn clientTask(self: *@This()) void {
            Io.sleep(self.client_io, .fromNanoseconds(10), .awake) catch @panic("sleep failed");
            const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4722) catch unreachable;
            const stream = address.connect(self.client_io, .{ .mode = .stream, .protocol = .tcp }) catch
                @panic("connect failed");
            defer stream.close(self.client_io);

            const data: [1][]const u8 = .{"queued"};
            _ = self.client_io.vtable.netWrite(
                self.client_io.userdata,
                stream.socket.handle,
                "",
                &data,
                1,
            ) catch @panic("write failed");
            self.sent = 1;
            self.client_io.futexWake(u32, &self.sent, 1);
        }
    };

    var world = try World.init(task_world_allocator, .{ .seed = 0xBACF, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{
        .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 4 },
    });
    try sim.control.network.setLatency(.{ .min_latency_ns = 1_000 });

    var scenario: Scenario = .{
        .server_io = (try sim.envForNode(0)).io(),
        .client_io = (try sim.envForNode(1)).io(),
    };
    var server = try Io.concurrent(scenario.server_io, Scenario.serverTask, .{&scenario});
    var client = try Io.concurrent(scenario.client_io, Scenario.clientTask, .{&scenario});
    client.await(scenario.client_io);
    server.await(scenario.server_io);

    const endpoint = try sim.byteEndpoint(1);
    var messages: [network_module.default_byte_pool_options.buffers]network_module.ByteEndpoint.Message = undefined;
    var acquired: usize = 0;
    defer for (messages[0..acquired]) |message| message.release();
    while (acquired < messages.len) : (acquired += 1) {
        messages[acquired] = try endpoint.acquire(1);
    }
}
