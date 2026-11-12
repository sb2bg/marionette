//! Application deadlines must survive scheduler tick rounding.
const std = @import("std");
const mar = @import("marionette");
const ms = std.time.ns_per_ms;

fn timeout(now: u64, after: u64, absolute: bool) std.Io.Timeout {
    return if (absolute)
        .{ .deadline = .{ .raw = .fromNanoseconds(now + after), .clock = .boot } }
    else
        .{ .duration = .{ .raw = .fromNanoseconds(after), .clock = .awake } };
}

const ConnectCase = struct {
    world: *mar.World,
    io: std.Io,
    after: u64,
    absolute: bool,

    fn run(self: *@This()) !void {
        const start = self.world.now();
        const result = mar.AnyNetworkControl.hostIp4(0, 7000).connect(self.io, .{
            .mode = .stream,
            .timeout = timeout(start, self.after, self.absolute),
        });
        defer if (result) |stream| stream.close(self.io) else |_| {};
        if (self.after <= 20 * ms) {
            try std.testing.expectError(error.Timeout, result);
            try mar.expectTraceContains(self.world.traceBytes(), "io.net.connect_timeout");
        } else {
            _ = try result;
        }
        try std.testing.expectEqual(start + 20 * ms, self.world.now());
    }
};

test "tcp_v1 deadlines: connect checks the raw deadline before accepting a rounded wake" {
    inline for (.{ false, true }) |in_task| {
        inline for (.{ false, true }) |absolute| {
            for ([_]u64{ 15 * ms, 20 * ms, 25 * ms }) |after| {
                var world = try mar.World.init(std.testing.allocator, .{ .seed = 90, .tick_ns = 10 * ms, .start_ns = 100 * ms });
                defer world.deinit();
                const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
                try sim.control.network.setLatency(.{ .min_latency_ns = 10 * ms });
                const server_io = (try sim.envForNode(0)).io();
                const client_io = (try sim.envForNode(1)).io();
                var listener = try mar.AnyNetworkControl.hostIp4(0, 7000).listen(server_io, .{});
                var scenario: ConnectCase = .{ .world = &world, .io = client_io, .after = after, .absolute = absolute };
                if (in_task) {
                    var future = try std.Io.concurrent(client_io, ConnectCase.run, .{&scenario});
                    try future.await(client_io);
                } else try scenario.run();
                listener.deinit(server_io);
                try sim.control.checkResources();
            }
        }
    }
}

const ReadCase = struct {
    world: *mar.World,
    io: std.Io,
    stream: std.Io.net.Stream,
    after: u64,
    absolute: bool,

    fn run(self: *@This()) !void {
        var buffer: [5]u8 = @splat(0);
        var data: [1][]u8 = .{&buffer};
        const start = self.world.now();
        const result = self.io.operateTimeout(.{ .net_read = .{ .socket_handle = self.stream.socket.handle, .data = &data } }, timeout(start, self.after, self.absolute));
        if (self.after <= 10 * ms) {
            try std.testing.expectError(error.Timeout, result);
            try std.testing.expectEqualSlices(u8, &@as([5]u8, @splat(0)), &buffer);
            // The late bytes remain unread. A zero-time poll consumes ready
            // data without blocking, even though its deadline is already due.
            const ready = try self.io.operateTimeout(.{ .net_read = .{ .socket_handle = self.stream.socket.handle, .data = &data } }, timeout(self.world.now(), 0, self.absolute));
            try std.testing.expectEqual(@as(usize, 5), (try ready.net_read).data_len);
        } else {
            try std.testing.expectEqual(@as(usize, 5), (try (try result).net_read).data_len);
        }
        try std.testing.expectEqualStrings("hello", &buffer);
        try std.testing.expectEqual(start + 10 * ms, self.world.now());
    }
};

test "tcp_v1 deadlines: timed reads leave late bytes unread and preserve ready polls" {
    inline for (.{ false, true }) |in_task| {
        inline for (.{ false, true }) |absolute| {
            for ([_]u64{ 5 * ms, 10 * ms, 15 * ms }) |after| {
                var world = try mar.World.init(std.testing.allocator, .{ .seed = 91, .tick_ns = 10 * ms });
                defer world.deinit();
                const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
                try sim.control.network.setLatency(.{ .min_latency_ns = 10 * ms });
                const server_io = (try sim.envForNode(0)).io();
                const client_io = (try sim.envForNode(1)).io();
                const address = mar.AnyNetworkControl.hostIp4(0, 7000);
                var listener = try address.listen(server_io, .{});
                defer listener.deinit(server_io);
                const client = try address.connect(client_io, .{ .mode = .stream });
                defer client.close(client_io);
                const server = try listener.accept(server_io);
                defer server.close(server_io);
                const bytes: [1][]const u8 = .{"hello"};
                _ = try (try client_io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &bytes, .header = "", .splat = 1 } })).net_write;
                var scenario: ReadCase = .{ .world = &world, .io = server_io, .stream = server, .after = after, .absolute = absolute };
                if (in_task) {
                    var future = try std.Io.concurrent(server_io, ReadCase.run, .{&scenario});
                    try future.await(server_io);
                } else try scenario.run();
            }
        }
    }
}

test "tcp_v1 deadlines: a timed out batch can retry its untouched submissions" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 92, .tick_ns = 10 * ms });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    try sim.control.network.setLatency(.{ .min_latency_ns = 10 * ms });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    const address = mar.AnyNetworkControl.hostIp4(0, 7000);
    var listener = try address.listen(server_io, .{});
    defer listener.deinit(server_io);
    const client = try address.connect(client_io, .{ .mode = .stream });
    defer client.close(client_io);
    const server = try listener.accept(server_io);
    defer server.close(server_io);
    const bytes: [1][]const u8 = .{"ab"};
    _ = try (try client_io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &bytes, .header = "", .splat = 1 } })).net_write;
    var buffers: [2][1]u8 = @splat(@splat(0));
    var data = [_][1][]u8{ .{&buffers[0]}, .{&buffers[1]} };
    var storage: [2]std.Io.Operation.Storage = undefined;
    var batch = std.Io.Batch.init(&storage);
    defer batch.cancel(server_io);
    for (&data) |*part| _ = batch.add(.{ .net_read = .{ .socket_handle = server.socket.handle, .data = part } });
    try std.testing.expectError(error.Timeout, batch.awaitConcurrent(server_io, timeout(world.now(), 5 * ms, false)));
    try std.testing.expect(batch.next() == null);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, std.mem.asBytes(&buffers));
    const start = world.now();
    try batch.awaitConcurrent(server_io, timeout(start, 0, false));
    for (0..2) |index| {
        const completion = batch.next().?;
        try std.testing.expectEqual(@as(u32, @intCast(index)), completion.index);
        try std.testing.expectEqual(@as(usize, 1), (try completion.result.net_read).data_len);
    }
    try std.testing.expect(batch.next() == null);
    try std.testing.expectEqualStrings("ab", std.mem.asBytes(&buffers));
    try std.testing.expectEqual(start, world.now());
}

test "tcp_v1 deadlines: a blocked write cannot consume capacity freed after its deadline" {
    inline for (.{ false, true }) |absolute| {
        var world = try mar.World.init(std.testing.allocator, .{ .seed = 93, .tick_ns = 10 * ms });
        defer world.deinit();
        const sim = try world.simulate(.{ .network = .{ .nodes = 2, .tcp = .{ .mss = 1, .send_buffer_bytes = 1, .receive_buffer_bytes = 1 } } });
        try sim.control.network.setLatency(.{ .min_latency_ns = 10 * ms });
        const server_io = (try sim.envForNode(0)).io();
        const client_io = (try sim.envForNode(1)).io();
        const address = mar.AnyNetworkControl.hostIp4(0, 7000);
        var listener = try address.listen(server_io, .{});
        defer listener.deinit(server_io);
        const client = try address.connect(client_io, .{ .mode = .stream });
        defer client.close(client_io);
        const server = try listener.accept(server_io);
        defer server.close(server_io);
        const first: [1][]const u8 = .{"a"};
        _ = try (try client_io.operate(.{ .net_write = .{ .socket_handle = client.socket.handle, .data = &first, .header = "", .splat = 1 } })).net_write;
        // The send buffer frees only after the peer's delayed ACK: 10 ms
        // delivery + 40 ms delayed ACK + 10 ms return trip.
        const second: [1][]const u8 = .{"b"};
        const operation: std.Io.Operation = .{ .net_write = .{ .socket_handle = client.socket.handle, .data = &second, .header = "", .splat = 1 } };
        const start = world.now();
        try std.testing.expectError(error.Timeout, client_io.operateTimeout(operation, timeout(start, 55 * ms, absolute)));
        try std.testing.expectEqual(start + 60 * ms, world.now());
        // Retrying without waiting succeeds only if the timed out operation
        // did not already consume the newly available send-buffer slot.
        try std.testing.expectEqual(@as(usize, 1), try (try client_io.operateTimeout(operation, timeout(world.now(), 0, absolute))).net_write);
        var buffer: [1]u8 = undefined;
        var data: [1][]u8 = .{&buffer};
        for ("ab") |expected| {
            try std.testing.expectEqual(@as(usize, 1), (try (try server_io.operate(.{ .net_read = .{ .socket_handle = server.socket.handle, .data = &data } })).net_read).data_len);
            try std.testing.expectEqual(expected, buffer[0]);
        }
    }
}
