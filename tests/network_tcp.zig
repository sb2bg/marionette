//! `tcp_v1` contract tests: handshake, data, close, and the Linux-shaped
//! fault outcomes the 0.9 network promises.
const std = @import("std");
const builtin = @import("builtin");
const mar = @import("marionette");

const ms = std.time.ns_per_ms;
const s = std.time.ns_per_s;
const fibers = builtin.os.tag == .macos or builtin.os.tag == .linux;

fn newWorld(seed: u64) !mar.World {
    return mar.World.init(std.testing.allocator, .{ .seed = seed, .tick_ns = 1 * ms });
}

fn tcpSim(world: *mar.World, nodes: usize) !mar.Sim {
    const sim = try world.simulate(.{ .network = .{ .nodes = nodes, .semantics = .tcp_v1 } });
    try sim.control.network.setLatency(.{ .min_latency_ns = 1 * ms });
    return sim;
}

fn serverAddress(port: u16) std.Io.net.IpAddress {
    return mar.AnyNetworkControl.hostIp4(0, port);
}

fn read(io: std.Io, stream: std.Io.net.Stream, buffer: []u8) !usize {
    var data: [1][]u8 = .{buffer};
    return (try (try io.operate(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } })).net_read).data_len;
}

fn writeAll(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const data: [1][]const u8 = .{bytes[offset..]};
        offset += try (try io.operate(.{ .net_write = .{ .socket_handle = stream.socket.handle, .header = "", .data = &data, .splat = 1 } })).net_write;
    }
}

test "tcp_v1: connect, exchange, and close over a real handshake" {
    var world = try newWorld(1);
    defer world.deinit();
    const sim = try tcpSim(&world, 2);
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const address = serverAddress(7000);
    var listener = try address.listen(server_io, .{});

    const client = try address.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
    // SYN, SYN-ACK: one round trip of 1 ms each way.
    try std.testing.expectEqual(@as(u64, 2 * ms), world.now());
    const server = try listener.accept(server_io);
    // The server sees the client's own address and ephemeral port.
    try std.testing.expect(server.socket.address.ip4.bytes[3] == 2);
    try std.testing.expect(server.socket.address.getPort() >= 32768);

    try writeAll(client_io, client, "hello");
    var buffer: [16]u8 = undefined;
    const count = try read(server_io, server, &buffer);
    try std.testing.expectEqualStrings("hello", buffer[0..count]);

    client.close(client_io);
    try std.testing.expectEqual(@as(usize, 0), try read(server_io, server, &buffer));
    server.close(server_io);
    listener.deinit(server_io);
    try sim.control.runFor(100 * ms);
    try sim.control.checkResources();
}

test "tcp_v1 probe F: hosts own addresses and port tables" {
    var world = try newWorld(2);
    defer world.deinit();
    const sim = try tcpSim(&world, 3);
    const io = [_]std.Io{ (try sim.envForNode(0)).io(), (try sim.envForNode(1)).io(), (try sim.envForNode(2)).io() };
    const any = std.Io.net.IpAddress.parseIp4("0.0.0.0", 7005) catch unreachable;
    var first = try any.listen(io[0], .{});
    defer first.deinit(io[0]);
    var second = try any.listen(io[1], .{});
    defer second.deinit(io[1]);
    try std.testing.expectError(error.AddressInUse, any.listen(io[1], .{}));
    try std.testing.expectError(error.AddressUnavailable, mar.AnyNetworkControl.hostIp4(0, 7006).listen(io[2], .{}));
    const unknown = std.Io.net.IpAddress.parseIp4("192.168.1.1", 7005) catch unreachable;
    try std.testing.expectError(error.NetworkUnreachable, unknown.connect(io[2], .{ .mode = .stream }));
}

test "tcp_v1 probe A: connect into a partition blocks until the caller's timeout" {
    var world = try newWorld(3);
    defer world.deinit();
    const sim = try tcpSim(&world, 2);
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    const address = serverAddress(7000);
    var listener = try address.listen(server_io, .{});
    defer listener.deinit(server_io);

    const fault = try sim.control.network.partition(&.{0}, &.{1}, .{});
    try std.testing.expectError(error.Timeout, address.connect(client_io, .{
        .mode = .stream,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }));
    try std.testing.expectEqual(@as(u64, 10 * s), world.now());
    try sim.control.network.healFault(fault);
}

test "tcp_v1: connect into a partition without a timeout gives up after SYN retries" {
    var world = try newWorld(4);
    defer world.deinit();
    const sim = try tcpSim(&world, 2);
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    const address = serverAddress(7000);
    var listener = try address.listen(server_io, .{});
    defer listener.deinit(server_io);
    _ = try sim.control.network.partition(&.{0}, &.{1}, .{});
    try std.testing.expectError(error.Timeout, address.connect(client_io, .{ .mode = .stream }));
    try std.testing.expectEqual(@as(u64, 127 * s), world.now());
}

test "tcp_v1: connecting to a closed port is refused after one round trip" {
    var world = try newWorld(5);
    defer world.deinit();
    const sim = try tcpSim(&world, 2);
    const client_io = (try sim.envForNode(1)).io();
    try std.testing.expectError(error.ConnectionRefused, serverAddress(7999).connect(client_io, .{ .mode = .stream }));
    try std.testing.expectEqual(@as(u64, 2 * ms), world.now());
}

const Pair = struct {
    sim: mar.Sim,
    server_io: std.Io,
    client_io: std.Io,
    harness_io: std.Io,
    listener: std.Io.net.Server,
    server: std.Io.net.Stream,
    client: std.Io.net.Stream,

    fn init(world: *mar.World, options: mar.SimNetworkOptions) !Pair {
        var network = options;
        network.semantics = .tcp_v1;
        const sim = try world.simulate(.{ .network = network });
        try sim.control.network.setLatency(.{ .min_latency_ns = 1 * ms });
        const server_io = (try sim.envForNode(0)).io();
        const client_io = (try sim.envForNode(1)).io();
        const address = serverAddress(7000);
        var listener = try address.listen(server_io, .{});
        errdefer listener.deinit(server_io);
        const client = try address.connect(client_io, .{ .mode = .stream });
        const server = try listener.accept(server_io);
        return .{
            .sim = sim,
            .server_io = server_io,
            .client_io = client_io,
            .harness_io = sim.env.io(),
            .listener = listener,
            .server = server,
            .client = client,
        };
    }
};

const Healer = struct {
    control: mar.Control,
    io: std.Io,
    after_ns: u64,
    fault: mar.NetworkFault,
    healed_at: u64 = 0,
    world: *mar.World,

    fn run(self: *Healer) void {
        std.Io.sleep(self.io, .fromNanoseconds(self.after_ns), .awake) catch return;
        self.control.network.healFault(self.fault) catch @panic("heal failed");
        self.healed_at = self.world.now();
    }
};

test "tcp_v1 probe B: a reply sent into a partition arrives after the heal" {
    var world = try newWorld(0xB);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2 });
    defer pair.listener.deinit(pair.server_io);
    defer pair.client.close(pair.client_io);
    defer pair.server.close(pair.server_io);

    const fault = try pair.sim.control.network.partition(&.{0}, &.{1}, .{});
    try writeAll(pair.server_io, pair.server, "reply");
    var healer: Healer = .{ .control = pair.sim.control, .io = pair.harness_io, .after_ns = 5 * s, .fault = fault, .world = &world };
    var future = try std.Io.concurrent(pair.harness_io, Healer.run, .{&healer});
    defer future.await(pair.harness_io);

    var buffer: [16]u8 = undefined;
    const count = try read(pair.client_io, pair.client, &buffer);
    try std.testing.expectEqualStrings("reply", buffer[0..count]);
    try std.testing.expect(world.now() > healer.healed_at);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "tcp.retransmit") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "reason=fault fault=1 mode=drop") != null);
}

test "tcp_v1 probe C: a close behind a partition reaches the peer after the heal" {
    var world = try newWorld(0xC);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2 });
    defer pair.listener.deinit(pair.server_io);
    defer pair.client.close(pair.client_io);

    const fault = try pair.sim.control.network.partition(&.{0}, &.{1}, .{});
    const start = world.now();
    pair.server.close(pair.server_io);
    var healer: Healer = .{ .control = pair.sim.control, .io = pair.harness_io, .after_ns = 2 * s, .fault = fault, .world = &world };
    var future = try std.Io.concurrent(pair.harness_io, Healer.run, .{&healer});
    defer future.await(pair.harness_io);

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try read(pair.client_io, pair.client, &buffer));
    try std.testing.expect(world.now() > start + 2 * s);
}

test "tcp_v1 probe D: a killed peer's FIN waits behind the partition too" {
    var world = try newWorld(0xD);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2 });
    defer pair.client.close(pair.client_io);

    const fault = try pair.sim.control.network.partition(&.{0}, &.{1}, .{});
    const start = world.now();
    try pair.sim.killProcess(0);
    // Node 0 hosts the default harness Io and is dead; heal from node 1.
    var healer: Healer = .{ .control = pair.sim.control, .io = pair.client_io, .after_ns = 2 * s, .fault = fault, .world = &world };
    var future = try std.Io.concurrent(pair.client_io, Healer.run, .{&healer});
    defer future.await(pair.client_io);

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try read(pair.client_io, pair.client, &buffer));
    try std.testing.expect(world.now() > start + 2 * s);
}

const Flood = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    write_error: ?anyerror = null,

    fn run(self: *Flood) void {
        var chunk: [4096]u8 = undefined;
        var sent: usize = 0;
        while (sent < total) {
            for (&chunk, 0..) |*byte, index| byte.* = @truncate(sent + index);
            writeAll(self.io, self.stream, &chunk) catch |err| {
                self.write_error = err;
                return;
            };
            sent += chunk.len;
        }
        self.stream.shutdown(self.io, .send) catch |err| {
            self.write_error = err;
        };
    }
    const total = 200 * 1024;
};

test "tcp_v1 probe E: light loss costs retransmissions, not the stream" {
    if (!fibers) return error.SkipZigTest;
    var world = try newWorld(0xE);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2 });
    defer pair.listener.deinit(pair.server_io);
    defer pair.client.close(pair.client_io);
    defer pair.server.close(pair.server_io);

    try pair.sim.control.network.setLossiness(.{ .drop_rate = .percent(1) });
    var flood: Flood = .{ .io = pair.client_io, .stream = pair.client };
    var future = try std.Io.concurrent(pair.client_io, Flood.run, .{&flood});
    var received: usize = 0;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = try read(pair.server_io, pair.server, &buffer);
        if (count == 0) break;
        for (buffer[0..count], 0..) |byte, index| {
            try std.testing.expectEqual(@as(u8, @truncate(received + index)), byte);
        }
        received += count;
    }
    future.await(pair.client_io);
    try std.testing.expectEqual(@as(?anyerror, null), flood.write_error);
    try std.testing.expectEqual(@as(usize, Flood.total), received);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "reason=loss") != null);
}

test "tcp_v1 probe G: a reader that never reads stalls only its own connection" {
    if (!fibers) return error.SkipZigTest;
    var world = try newWorld(0x6);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2 });
    defer pair.listener.deinit(pair.server_io);
    defer pair.client.close(pair.client_io);
    defer pair.server.close(pair.server_io);

    // The first connection's reader never reads: its writer fills both
    // buffers and blocks.
    var flood: Flood = .{ .io = pair.client_io, .stream = pair.client };
    var future = try std.Io.concurrent(pair.client_io, Flood.run, .{&flood});
    defer future.cancel(pair.client_io);
    try std.Io.sleep(pair.harness_io, .fromNanoseconds(100 * ms), .awake);

    // A second connection still carries data at once.
    const second = try serverAddress(7000).connect(pair.client_io, .{ .mode = .stream });
    defer second.close(pair.client_io);
    const second_server = try pair.listener.accept(pair.server_io);
    defer second_server.close(pair.server_io);
    try writeAll(pair.client_io, second, "independent");
    var buffer: [32]u8 = undefined;
    const count = try read(pair.server_io, second_server, &buffer);
    try std.testing.expectEqualStrings("independent", buffer[0..count]);
}

const Reader = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    result: ?anyerror = null,

    fn run(self: *Reader) void {
        var buffer: [16]u8 = undefined;
        _ = read(self.io, self.stream, &buffer) catch |err| {
            self.result = err;
            return;
        };
    }
};

test "tcp_v1: a missing application timeout surfaces as a deadlock" {
    if (!fibers) return error.SkipZigTest;
    var world = try newWorld(0xDEAD);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2 });
    defer pair.listener.deinit(pair.server_io);
    defer pair.server.close(pair.server_io);

    _ = try pair.sim.control.network.partition(&.{0}, &.{1}, .{});
    var reader: Reader = .{ .io = pair.client_io, .stream = pair.client };
    var future = try std.Io.concurrent(pair.client_io, Reader.run, .{&reader});
    try std.testing.expectError(error.Deadlock, pair.sim.control.runTasksUntilIdle());
    pair.client.close(pair.client_io);
    future.cancel(pair.client_io);
}

test "tcp_v1: data into a partition times out after Linux retransmission exhaustion" {
    var world = try newWorld(0x77);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2, .timing = .compressed });
    defer pair.listener.deinit(pair.server_io);
    defer pair.client.close(pair.client_io);
    defer pair.server.close(pair.server_io);

    _ = try pair.sim.control.network.partition(&.{0}, &.{1}, .{});
    try writeAll(pair.client_io, pair.client, "lost");
    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.ConnectionTimedOut, read(pair.client_io, pair.client, &buffer));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "tcp.retransmit conn=2 seq=1 attempt=15") != null);
}

test "tcp_v1: a reject fault refuses a connect with HostUnreachable" {
    var world = try newWorld(0x88);
    defer world.deinit();
    const sim = try tcpSim(&world, 2);
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    var listener = try serverAddress(7000).listen(server_io, .{});
    defer listener.deinit(server_io);
    _ = try sim.control.network.cut(1, 0, .{ .mode = .reject });
    try std.testing.expectError(error.HostUnreachable, serverAddress(7000).connect(client_io, .{ .mode = .stream }));
    try std.testing.expectEqual(@as(u64, 2 * ms), world.now());
}

test "tcp_v1: an absent host fails like an ARP timeout" {
    var world = try newWorld(0x89);
    defer world.deinit();
    const sim = try tcpSim(&world, 2);
    const client_io = (try sim.envForNode(1)).io();
    try std.testing.expectError(error.HostUnreachable, mar.AnyNetworkControl.hostIp4(9, 7000).connect(client_io, .{ .mode = .stream }));
    try std.testing.expectEqual(@as(u64, 3 * s), world.now());
}

test "tcp_v1: a hold fault delays packets until it heals" {
    var world = try newWorld(0x90);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2 });
    defer pair.listener.deinit(pair.server_io);
    defer pair.client.close(pair.client_io);
    defer pair.server.close(pair.server_io);

    _ = try pair.sim.control.network.cut(1, 0, .{ .mode = .hold, .duration_ns = 50 * ms });
    const start = world.now();
    try writeAll(pair.client_io, pair.client, "held");
    var buffer: [16]u8 = undefined;
    const count = try read(pair.server_io, pair.server, &buffer);
    try std.testing.expectEqualStrings("held", buffer[0..count]);
    try std.testing.expectEqual(start + 50 * ms, world.now());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "net.hold pkt=") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "net.release pkt=") != null);
}

test "tcp_v1: the simulated DNS resolves node names" {
    var world = try newWorld(0x91);
    defer world.deinit();
    const sim = try tcpSim(&world, 2);
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    try sim.control.network.addHostName("db.internal", 0);
    var listener = try serverAddress(7000).listen(server_io, .{});
    defer listener.deinit(server_io);
    const name = try std.Io.net.HostName.init("db.internal");
    const stream = try name.connect(client_io, 7000, .{ .mode = .stream });
    stream.close(client_io);
    const by_index = try std.Io.net.HostName.init("node0");
    const second = try by_index.connect(client_io, 7000, .{ .mode = .stream });
    second.close(client_io);
}

test "tcp_v1: operateTimeout gives reads a real application timeout" {
    var world = try newWorld(0x92);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2 });
    defer pair.listener.deinit(pair.server_io);
    defer pair.client.close(pair.client_io);
    defer pair.server.close(pair.server_io);

    var buffer: [16]u8 = undefined;
    var data: [1][]u8 = .{&buffer};
    const start = world.now();
    try std.testing.expectError(error.Timeout, pair.client_io.operateTimeout(
        .{ .net_read = .{ .socket_handle = pair.client.socket.handle, .data = &data } },
        .{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } },
    ));
    try std.testing.expectEqual(start + 250 * ms, world.now());

    try writeAll(pair.server_io, pair.server, "late");
    const result = try pair.client_io.operateTimeout(
        .{ .net_read = .{ .socket_handle = pair.client.socket.handle, .data = &data } },
        .{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } },
    );
    const count = (try result.net_read).data_len;
    try std.testing.expectEqualStrings("late", buffer[0..count]);
}

const CapsuleApp = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }

    fn scenario(case: *mar.SimCase(@This())) !void {
        const server_io = (try case.sim.envForNode(0)).io();
        const client_io = (try case.sim.envForNode(1)).io();
        try case.control().network.setLossiness(.{ .drop_rate = .percent(20) });
        const address = serverAddress(7100);
        var listener = try address.listen(server_io, .{});
        defer listener.deinit(server_io);
        const client = try address.connect(client_io, .{ .mode = .stream });
        defer client.close(client_io);
        const server = try listener.accept(server_io);
        defer server.close(server_io);
        try writeAll(client_io, client, "capsule");
        var buffer: [16]u8 = undefined;
        const count = try read(server_io, server, &buffer);
        try case.env().record("app.read len={}", .{count});
    }
};

test "tcp_v1: capsules record the network model and replay exactly" {
    const identity: mar.ReplayIdentity = .{ .build = "tcp-test", .sut = "capsule" };
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0x5eed,
        .tick_ns = 1 * ms,
        .simulate = mar.World.SimulateOptions{ .network = .{ .nodes = 2, .semantics = .tcp_v1, .timing = .compressed } },
        .init = CapsuleApp.init,
        .scenario = CapsuleApp.scenario,
    });
    defer report.deinit();
    try std.testing.expect(report == .passed);
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"semantics\":\"tcp_v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"model_version\":1") != null);

    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    try std.testing.expectEqual(mar.NetworkSemantics.tcp_v1, capsule.simulateOptions().network.?.semantics);
    var replay = try mar.replaySimCase(.{ .allocator = std.testing.allocator, .init = CapsuleApp.init, .scenario = CapsuleApp.scenario }, &capsule, identity);
    defer replay.deinit();
    try std.testing.expect(replay == .passed);

    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "\"model_version\":1", "\"model_version\":2");
    defer std.testing.allocator.free(changed);
    try std.testing.expectError(error.IncompatibleNetworkModel, mar.ReplayCapsule.decode(std.testing.allocator, changed));

    // A capsule written before 0.9 names no model and replays as legacy.
    const legacy = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "\"semantics\":\"tcp_v1\",", "");
    defer std.testing.allocator.free(legacy);
    var legacy_capsule = try mar.ReplayCapsule.decode(std.testing.allocator, legacy);
    defer legacy_capsule.deinit();
    try std.testing.expectEqual(mar.NetworkSemantics.legacy_v0, legacy_capsule.simulateOptions().network.?.semantics);
}

test "tcp_v1: closing over unread data resets the peer" {
    var world = try newWorld(0x93);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2 });
    defer pair.listener.deinit(pair.server_io);
    defer pair.client.close(pair.client_io);

    try writeAll(pair.client_io, pair.client, "unread");
    try pair.sim.control.runFor(10 * ms);
    pair.server.close(pair.server_io);
    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.ConnectionResetByPeer, read(pair.client_io, pair.client, &buffer));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "tcp.reset conn=3 host=0 reason=close_unread") != null);
}

test "tcp_v1: a disk crash is a machine crash: sockets vanish without a packet" {
    var world = try newWorld(0x94);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2 });
    const sends_before = std.mem.count(u8, world.traceBytes(), "net.send ");

    try pair.sim.control.disk.crash();
    try std.testing.expectEqual(sends_before, std.mem.count(u8, world.traceBytes(), "net.send "));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "tcp.machine_crash host=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "tcp.machine_crash host=1") != null);

    try pair.sim.control.process.restart(0);
    try pair.sim.control.process.restart(1);
    const server_io = (try pair.sim.envForNode(0)).io();
    const client_io = (try pair.sim.envForNode(1)).io();
    var listener = try serverAddress(7000).listen(server_io, .{});
    defer listener.deinit(server_io);
    const client = try serverAddress(7000).connect(client_io, .{ .mode = .stream });
    client.close(client_io);
}

test "tcp_v1: degrade adds latency to one direction" {
    var world = try newWorld(0x95);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2 });
    defer pair.listener.deinit(pair.server_io);
    defer pair.client.close(pair.client_io);
    defer pair.server.close(pair.server_io);

    const fault = try pair.sim.control.network.degrade(1, 0, .{ .delay_ns = 20 * ms });
    const start = world.now();
    try writeAll(pair.client_io, pair.client, "slow");
    var buffer: [16]u8 = undefined;
    _ = try read(pair.server_io, pair.server, &buffer);
    try std.testing.expectEqual(start + 21 * ms, world.now());
    try pair.sim.control.network.healFault(fault);
    try std.testing.expectError(error.FaultNotActive, pair.sim.control.network.healFault(fault));
}

test "tcp_v1: healing one fault leaves the others" {
    var world = try newWorld(0x96);
    defer world.deinit();
    const sim = try tcpSim(&world, 3);
    const first = try sim.control.network.isolate(2, .{});
    const second = try sim.control.network.partition(&.{0}, &.{1}, .{});
    try std.testing.expectEqual(@as(usize, 2), sim.control.network.activeFaultCount());
    try sim.control.network.healFault(first);
    try std.testing.expectEqual(@as(usize, 1), sim.control.network.activeFaultCount());
    try sim.control.network.healFault(second);
    try std.testing.expectEqual(@as(usize, 0), sim.control.network.activeFaultCount());
    const expiring = try sim.control.network.cut(0, 1, .{ .duration_ns = 5 * ms });
    try sim.control.runFor(5 * ms);
    try std.testing.expectError(error.FaultNotActive, sim.control.network.healFault(expiring));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.fault_heal fault=3 reason=expired") != null);
}

test "tcp_v1: a deadlock records a netstat table of sockets and faults" {
    if (!fibers) return error.SkipZigTest;
    var world = try newWorld(0xDEAE);
    defer world.deinit();
    var pair = try Pair.init(&world, .{ .nodes = 2 });
    defer pair.listener.deinit(pair.server_io);
    defer pair.server.close(pair.server_io);

    _ = try pair.sim.control.network.partition(&.{0}, &.{1}, .{});
    var reader: Reader = .{ .io = pair.client_io, .stream = pair.client };
    var future = try std.Io.concurrent(pair.client_io, Reader.run, .{&reader});
    try std.testing.expectError(error.Deadlock, pair.sim.control.runTasksUntilIdle());
    const trace = world.traceBytes();
    try std.testing.expect(std.mem.indexOf(u8, trace, "netstat.begin reason=deadlock") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "netstat.tcp conn=2 host=1 state=ESTABLISHED") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "netstat.listen sock=1 host=0 local=10.0.0.1:7000") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "netstat.fault fault=1 kind=partition mode=drop paths=2") != null);
    pair.client.close(pair.client_io);
    future.cancel(pair.client_io);
}

test "tcp_v1: a window probe recovers a lost window update" {
    if (!fibers) return error.SkipZigTest;
    var world = try newWorld(0x97);
    defer world.deinit();
    var pair = try Pair.init(&world, .{
        .nodes = 2,
        .timing = .compressed,
        .tcp = .{ .send_buffer_bytes = 8 * 1024, .receive_buffer_bytes = 8 * 1024 },
    });
    defer pair.listener.deinit(pair.server_io);
    defer pair.client.close(pair.client_io);
    defer pair.server.close(pair.server_io);

    var flood: Flood = .{ .io = pair.client_io, .stream = pair.client };
    var future = try std.Io.concurrent(pair.client_io, Flood.run, .{&flood});
    // Both buffers fill and the client's view of the window drops to zero.
    try std.Io.sleep(pair.harness_io, .fromNanoseconds(100 * ms), .awake);

    // Every window update the reader sends while draining its full buffer is
    // lost, so only a window probe can tell the writer the window reopened.
    const cut = try pair.sim.control.network.cut(0, 1, .{});
    var buffer: [4096]u8 = undefined;
    var received: usize = 0;
    while (received < 8 * 1024) received += try read(pair.server_io, pair.server, &buffer);
    // Faults are judged when a packet arrives; keep the cut until it has.
    try std.Io.sleep(pair.harness_io, .fromNanoseconds(5 * ms), .awake);
    try pair.sim.control.network.healFault(cut);

    while (true) {
        const count = try read(pair.server_io, pair.server, &buffer);
        if (count == 0) break;
        received += count;
    }
    future.await(pair.client_io);
    try std.testing.expectEqual(@as(?anyerror, null), flood.write_error);
    try std.testing.expectEqual(@as(usize, Flood.total), received);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "tcp.window_probe conn=2") != null);
}
