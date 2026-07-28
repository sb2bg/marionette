//! Portable no-fault `std.Io.net` observations compared with the host backend.

const std = @import("std");
const mar = @import("marionette");

const Io = std.Io;

const Outcome = struct {
    accepted_peer_has_nonzero_port: bool = false,
    server_read: [4]u8 = undefined,
    server_read_len: usize = 0,
    client_read: [4]u8 = undefined,
    client_read_len: usize = 0,
    client_saw_eof: bool = false,
};

const ServerTask = struct {
    io: Io,
    server: *Io.net.Server,
    outcome: *Outcome,

    fn run(self: *@This()) void {
        const stream = self.server.accept(self.io) catch @panic("differential accept failed");
        defer stream.close(self.io);
        self.outcome.accepted_peer_has_nonzero_port = stream.socket.address.getPort() != 0;

        var read_buffers: [1][]u8 = .{&self.outcome.server_read};
        self.outcome.server_read_len = self.io.vtable.netRead(
            self.io.userdata,
            stream.socket.handle,
            &read_buffers,
        ) catch @panic("differential server read failed");

        const write_buffers: [1][]const u8 = .{"pong"};
        const written = self.io.vtable.netWrite(
            self.io.userdata,
            stream.socket.handle,
            "",
            &write_buffers,
            1,
        ) catch @panic("differential server write failed");
        if (written != 4) @panic("differential short server write");
        stream.shutdown(self.io, .send) catch @panic("differential server shutdown failed");
    }
};

fn runExchange(
    io: Io,
    server: *Io.net.Server,
    client_io: Io,
    connect_address: Io.net.IpAddress,
    outcome: *Outcome,
) !void {
    var server_task = ServerTask{ .io = io, .server = server, .outcome = outcome };
    var future = try Io.concurrent(io, ServerTask.run, .{&server_task});

    const client = try connect_address.connect(client_io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer client.close(client_io);

    const write_buffers: [1][]const u8 = .{"ping"};
    try std.testing.expectEqual(
        @as(usize, 4),
        try client_io.vtable.netWrite(
            client_io.userdata,
            client.socket.handle,
            "",
            &write_buffers,
            1,
        ),
    );

    var read_buffers: [1][]u8 = .{&outcome.client_read};
    outcome.client_read_len = try client_io.vtable.netRead(
        client_io.userdata,
        client.socket.handle,
        &read_buffers,
    );
    var eof_byte: [1]u8 = undefined;
    var eof_buffers: [1][]u8 = .{&eof_byte};
    outcome.client_saw_eof = try client_io.vtable.netRead(
        client_io.userdata,
        client.socket.handle,
        &eof_buffers,
    ) == 0;

    future.await(io);
}

fn hostOutcome() !Outcome {
    const io = std.testing.io;
    const bind_address = Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try bind_address.listen(io, .{});
    defer server.deinit(io);

    var outcome: Outcome = .{};
    try runExchange(io, &server, io, server.socket.address, &outcome);
    return outcome;
}

fn simulatedOutcome() !Outcome {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 0xD1FF, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 8 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();

    const bind_address = Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try bind_address.listen(server_io, .{});
    defer server.deinit(server_io);

    var outcome: Outcome = .{};
    try runExchange(server_io, &server, client_io, server.socket.address, &outcome);
    return outcome;
}

test "std.Io.net no-fault stream behavior matches the host backend" {
    const host = try hostOutcome();
    const simulated = try simulatedOutcome();

    try std.testing.expect(host.accepted_peer_has_nonzero_port);
    try std.testing.expectEqual(host.accepted_peer_has_nonzero_port, simulated.accepted_peer_has_nonzero_port);
    try std.testing.expectEqual(host.server_read_len, simulated.server_read_len);
    try std.testing.expectEqualStrings(host.server_read[0..host.server_read_len], simulated.server_read[0..simulated.server_read_len]);
    try std.testing.expectEqual(host.client_read_len, simulated.client_read_len);
    try std.testing.expectEqualStrings(host.client_read[0..host.client_read_len], simulated.client_read[0..simulated.client_read_len]);
    try std.testing.expectEqual(host.client_saw_eof, simulated.client_saw_eof);
}

fn hostWildcardOutcome() !Outcome {
    const io = std.testing.io;
    const wildcard = Io.net.IpAddress.parseIp4("0.0.0.0", 0) catch unreachable;
    var server = try wildcard.listen(io, .{});
    defer server.deinit(io);
    const loopback = Io.net.IpAddress.parseIp4(
        "127.0.0.1",
        server.socket.address.getPort(),
    ) catch unreachable;

    var outcome: Outcome = .{};
    try runExchange(io, &server, io, loopback, &outcome);
    return outcome;
}

fn simulatedWildcardOutcome() !Outcome {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 0xD1FE, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 8 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    const wildcard = Io.net.IpAddress.parseIp4("0.0.0.0", 0) catch unreachable;
    var server = try wildcard.listen(server_io, .{});
    defer server.deinit(server_io);
    const loopback = Io.net.IpAddress.parseIp4(
        "127.0.0.1",
        server.socket.address.getPort(),
    ) catch unreachable;

    var outcome: Outcome = .{};
    try runExchange(server_io, &server, client_io, loopback, &outcome);
    return outcome;
}

test "std.Io.net wildcard listener behavior matches the host backend" {
    const host = try hostWildcardOutcome();
    const simulated = try simulatedWildcardOutcome();

    try std.testing.expectEqual(host.accepted_peer_has_nonzero_port, simulated.accepted_peer_has_nonzero_port);
    try std.testing.expectEqual(host.server_read_len, simulated.server_read_len);
    try std.testing.expectEqualStrings(host.server_read[0..host.server_read_len], simulated.server_read[0..simulated.server_read_len]);
    try std.testing.expectEqual(host.client_read_len, simulated.client_read_len);
    try std.testing.expectEqualStrings(host.client_read[0..host.client_read_len], simulated.client_read[0..simulated.client_read_len]);
    try std.testing.expectEqual(host.client_saw_eof, simulated.client_saw_eof);
}
