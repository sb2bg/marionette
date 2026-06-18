const std = @import("std");

const Backend = @import("backend.zig").Backend;
const disk_module = @import("../disk/root.zig");
const env_module = @import("../env.zig");
const World = @import("../world.zig").World;
const Io = std.Io;

fn testIo(world: *World) Backend {
    return .init(std.testing.allocator, world, disk_module.Disk.unavailable(), 4096);
}

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

    flag = 1;
    server_io.futexWake(u32, &flag, 1);
    try std.testing.expectError(error.Deadlock, sim.control.runTasksUntilIdle());
    try std.testing.expectEqual(@as(usize, 1), sim.control.blockedTaskCount());

    client_io.futexWake(u32, &flag, 1);
    future.await(client_io);
    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
}

test "io: disk crash closes process-local std.Io.net listeners" {
    var world = try World.init(task_world_allocator, .{ .seed = 0xA5B, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4573) catch unreachable;
    var server = try address.listen(server_io, .{});
    defer server.deinit(server_io);

    try sim.control.disk.crash();
    try sim.control.disk.restart();

    try std.testing.expectError(
        error.ConnectionRefused,
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

    const server_backend = try sim.io_runtime.backendForNode(0);
    const client_backend = try sim.io_runtime.backendForNode(1);
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
        try std.testing.expectError(
            error.FileNotFound,
            Io.Dir.cwd().createFile(sim.env.io(), path, .{}),
        );
    }
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
