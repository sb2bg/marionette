//! Network characterization: how today's stream model reacts to partitions,
//! closes, kills, loss, and binds. These tests record current behavior, not
//! the goal. Each one notes what Linux TCP does instead; 0.9 (see ROADMAP.md)
//! changes the model so each expectation changes deliberately rather than by
//! accident. Probe letters match SIMULATOR_FINDINGS.md.
const std = @import("std");
const builtin = @import("builtin");
const mar = @import("marionette");

const ms = std.time.ns_per_ms;
const fibers = builtin.os.tag == .macos or builtin.os.tag == .linux;

const Pair = struct {
    world: *mar.World,
    sim: mar.Sim,
    server_io: std.Io,
    client_io: std.Io,
    server: std.Io.net.Stream,
    client: std.Io.net.Stream,
    listener: std.Io.net.Server,

    /// Two nodes, 1 ms ticks and latency, and one established stream.
    fn init(world: *mar.World, port: u16) !Pair {
        const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
        try sim.control.network.setLatency(.{ .min_latency_ns = 1 * ms });
        const server_io = (try sim.envForNode(0)).io();
        const client_io = (try sim.envForNode(1)).io();
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
        var listener = try address.listen(server_io, .{});
        errdefer listener.deinit(server_io);
        const client = try address.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
        const server = try listener.accept(server_io);
        return .{ .world = world, .sim = sim, .server_io = server_io, .client_io = client_io, .server = server, .client = client, .listener = listener };
    }

    fn deinit(self: *Pair) void {
        self.listener.deinit(self.server_io);
    }
};

fn read(io: std.Io, stream: std.Io.net.Stream, buffer: []u8) !usize {
    var data: [1][]u8 = .{buffer};
    return (try (try io.operate(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } })).net_read).data_len;
}

fn write(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !usize {
    const data: [1][]const u8 = .{bytes};
    return try (try io.operate(.{ .net_write = .{ .socket_handle = stream.socket.handle, .header = "", .data = &data, .splat = 1 } })).net_write;
}

fn newWorld(seed: u64) !mar.World {
    return mar.World.init(std.testing.allocator, .{ .seed = seed, .tick_ns = 1 * ms });
}

test "network probe A: connect into a partition fails at once, even with a timeout" {
    // Linux: SYNs are retransmitted at 1, 2, 4... s; connect blocks until the
    // caller's timeout, or about 127 s without one, then times out.
    var world = try newWorld(0xA);
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    try sim.control.network.setLatency(.{ .min_latency_ns = 1 * ms });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 7000) catch unreachable;
    var listener = try address.listen(server_io, .{});
    defer listener.deinit(server_io);

    try sim.control.network.partition(&.{0}, &.{1});
    const start = world.now();
    try std.testing.expectError(error.HostUnreachable, address.connect(client_io, .{ .mode = .stream, .protocol = .tcp }));
    try std.testing.expectError(error.HostUnreachable, address.connect(client_io, .{
        .mode = .stream,
        .protocol = .tcp,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }));
    try std.testing.expectEqual(start, world.now());
}

test "network probe B: a reply sent into a partition becomes a read error" {
    // Linux: the reply is retransmitted and arrives after the heal; a read
    // with no timeout just blocks until then.
    var world = try newWorld(0xB);
    defer world.deinit();
    var pair = try Pair.init(&world, 7001);
    defer pair.deinit();
    defer pair.client.close(pair.client_io);
    defer pair.server.close(pair.server_io);

    try pair.sim.control.network.partition(&.{0}, &.{1});
    const start = world.now();
    _ = try write(pair.server_io, pair.server, "reply");
    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.ConnectionTimedOut, read(pair.client_io, pair.client, &buffer));
    try std.testing.expectEqual(start + 1 * ms, world.now());
}

test "network probe C: a close crosses a partition at once" {
    // Linux: the FIN is lost; the read blocks until the heal and the FIN's
    // retransmission.
    var world = try newWorld(0xC);
    defer world.deinit();
    var pair = try Pair.init(&world, 7002);
    defer pair.deinit();
    defer pair.client.close(pair.client_io);

    try pair.sim.control.network.partition(&.{0}, &.{1});
    const start = world.now();
    pair.server.close(pair.server_io);
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try read(pair.client_io, pair.client, &buffer));
    try std.testing.expectEqual(start, world.now());
}

test "network probe D: a peer's death crosses a partition at once" {
    // Linux: the kernel's FIN is lost; the read blocks until the heal, then
    // returns EOF. If the whole machine died, it blocks until keepalive or an
    // application timeout.
    var world = try newWorld(0xD);
    defer world.deinit();
    var pair = try Pair.init(&world, 7003);
    defer pair.deinit();
    defer pair.client.close(pair.client_io);

    try pair.sim.control.network.partition(&.{0}, &.{1});
    const start = world.now();
    try pair.sim.killProcess(0);
    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.ConnectionResetByPeer, read(pair.client_io, pair.client, &buffer));
    try std.testing.expectEqual(start, world.now());
}

const Flood = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    sent: usize = 0,
    write_error: ?anyerror = null,

    fn run(self: *Flood) void {
        const chunk: [4096]u8 = @splat('x');
        while (self.sent < total) {
            self.sent += write(self.io, self.stream, &chunk) catch |err| {
                self.write_error = err;
                return;
            };
        }
    }
    const total = 200 * 1024;
};

test "network probe E: light loss kills an established stream" {
    // Linux: every byte arrives; each lost segment costs a retransmission
    // after at least 200 ms.
    if (!fibers) return error.SkipZigTest;
    var world = try newWorld(0xE);
    defer world.deinit();
    var pair = try Pair.init(&world, 7004);
    defer pair.deinit();
    defer pair.client.close(pair.client_io);
    defer pair.server.close(pair.server_io);

    try pair.sim.control.network.setLossiness(.{ .drop_rate = .percent(1) });
    var flood: Flood = .{ .io = pair.client_io, .stream = pair.client };
    var future = try std.Io.concurrent(pair.client_io, Flood.run, .{&flood});
    var received: usize = 0;
    var buffer: [4096]u8 = undefined;
    const read_error: anyerror = while (true) {
        const count = read(pair.server_io, pair.server, &buffer) catch |err| break err;
        if (count == 0) break error.EndOfStream;
        received += count;
    };
    future.await(pair.client_io);
    try std.testing.expect(received < Flood.total);
    try std.testing.expectEqual(error.ConnectionTimedOut, read_error);
}

test "network probe F: one port namespace for the whole world" {
    // Linux: each host binds its own addresses, so every node can listen on
    // 0.0.0.0:7000, and no node can bind another host's address.
    var world = try newWorld(0xF);
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 3 } });
    const io = [_]std.Io{ (try sim.envForNode(0)).io(), (try sim.envForNode(1)).io(), (try sim.envForNode(2)).io() };
    const any = std.Io.net.IpAddress.parseIp4("0.0.0.0", 7005) catch unreachable;
    var first = try any.listen(io[0], .{});
    defer first.deinit(io[0]);
    try std.testing.expectError(error.AddressInUse, any.listen(io[1], .{}));
    try std.testing.expectError(error.AddressInUse, any.listen(io[2], .{}));

    // Node 2 binds an address no host owns.
    const foreign = std.Io.net.IpAddress.parseIp4("10.0.0.1", 7006) catch unreachable;
    var borrowed = try foreign.listen(io[2], .{});
    borrowed.deinit(io[2]);
}
