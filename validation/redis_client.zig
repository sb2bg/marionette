//! Pinned, unmodified lalinsky/redis.zig against a scripted RESP2 peer.
//! The peer checks exact commands and counts executed increments independently.
//! Lost replies characterize retry semantics, not an exactly-once guarantee.
const std = @import("std");
const mar = @import("marionette");
const redis = @import("redis");
const Io = std.Io;
const address = Io.net.IpAddress.parseIp4("127.0.0.1", 6379) catch unreachable;
const Mode = enum { normal, fragmented, lost_reply, no_retry, pipeline_cut };
const incr = "*2\r\n$4\r\nINCR\r\n$7\r\ncounter\r\n";
const ping = "*1\r\n$4\r\nPING\r\n";

const Scenario = struct {
    allocator: std.mem.Allocator,
    world: *mar.World,
    server_io: Io,
    client_io: Io,
    mode: Mode,
    ready: u32 = 0,
    executed: u32 = 0,
    connections: u32 = 0,
    client_completed: bool = false,
    server_completed: bool = false,

    fn expectCommand(reader: *Io.Reader, expected: []const u8) !void {
        var buffer: [256]u8 = undefined;
        const bytes = buffer[0..expected.len];
        try reader.readSliceAll(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
    }

    fn send(self: *Scenario, writer: *Io.Writer, bytes: []const u8) !void {
        if (self.mode == .fragmented) {
            for (bytes) |byte| {
                try writer.writeByte(byte);
                try writer.flush();
                try Io.sleep(self.server_io, .fromNanoseconds(100), .awake);
            }
        } else {
            try writer.writeAll(bytes);
            try writer.flush();
        }
    }

    fn serveConnection(self: *Scenario, stream: Io.net.Stream, first: bool) !void {
        defer stream.close(self.server_io);
        self.connections += 1;
        var rb: [256]u8 = undefined;
        var wb: [256]u8 = undefined;
        var reader = stream.reader(self.server_io, &rb);
        var writer = stream.writer(self.server_io, &wb);
        const r = &reader.interface;
        const w = &writer.interface;
        if (first) {
            try expectCommand(r, incr);
            self.executed += 1;
            try self.world.record("redis.peer.executed count={d}", .{self.executed});
            switch (self.mode) {
                .lost_reply, .no_retry => return, // Applied, but no response reaches the caller.
                .pipeline_cut => {
                    try expectCommand(r, incr);
                    self.executed += 1;
                    try self.send(w, ":1\r\n:2\r"); // Second result lacks its final LF.
                    return;
                },
                .normal, .fragmented => {},
            }
            try self.send(w, ":1\r\n");
            try expectCommand(r, incr);
            try self.send(w, "-ERR counter unavailable\r\n");
        } else if (self.mode == .lost_reply) {
            try expectCommand(r, incr);
            self.executed += 1;
            try self.world.record("redis.peer.executed count={d}", .{self.executed});
            try self.send(w, ":2\r\n");
        }
        try expectCommand(r, ping);
        try self.send(w, "+PONG\r\n");
        // Wait for client cleanup, so pooled-connection checks happen while live.
        try std.testing.expectError(error.EndOfStream, r.takeByte());
    }

    fn server(self: *Scenario) !void {
        var listener = try address.listen(self.server_io, .{});
        defer listener.deinit(self.server_io);
        self.ready = 1;
        self.server_io.futexWake(u32, &self.ready, 1);
        try self.serveConnection(try listener.accept(self.server_io), true);
        switch (self.mode) {
            .lost_reply, .no_retry, .pipeline_cut => try self.serveConnection(try listener.accept(self.server_io), false),
            else => {},
        }
        self.server_completed = true;
    }

    fn clientTask(self: *Scenario) !void {
        // Readiness belongs to the server node: futex keys are process-scoped.
        while (self.ready == 0) try self.server_io.futexWait(u32, &self.ready, 0);
        var client = try redis.Client.init(self.allocator, self.client_io, "127.0.0.1:6379", .{
            .retry_attempts = if (self.mode == .no_retry or self.mode == .pipeline_cut) 0 else 2,
        });
        defer client.deinit();
        switch (self.mode) {
            .normal, .fragmented => {
                try std.testing.expectEqual(@as(i64, 1), try client.incr("counter"));
                try std.testing.expectError(error.RedisError, client.incr("counter"));
            },
            .lost_reply => try std.testing.expectEqual(@as(i64, 2), try client.incr("counter")),
            .no_retry => try std.testing.expectError(error.EndOfStream, client.incr("counter")),
            .pipeline_cut => {
                var pipeline = try client.pipeline();
                defer pipeline.deinit();
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                try pipeline.incr("counter");
                try pipeline.incr("counter");
                try std.testing.expectError(error.EndOfStream, pipeline.exec(&arena));
            },
        }
        try client.ping();
        try self.world.record("redis.client.recovered", .{});
        self.client_completed = true;
    }
};

fn run(allocator: std.mem.Allocator, seed: u64, mode: Mode) ![]u8 {
    var world = try mar.World.init(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 32 } });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });
    var scenario: Scenario = .{ .allocator = allocator, .world = &world, .server_io = server_io, .client_io = client_io, .mode = mode };
    var server = try Io.concurrent(server_io, Scenario.server, .{&scenario});
    defer server.cancel(server_io) catch {};
    var client = try Io.concurrent(client_io, Scenario.clientTask, .{&scenario});
    defer client.cancel(client_io) catch {};
    try client.await(client_io);
    try server.await(server_io);
    try std.testing.expect(scenario.client_completed);
    try std.testing.expect(scenario.server_completed);
    const interrupted = mode == .lost_reply or mode == .no_retry or mode == .pipeline_cut;
    try std.testing.expectEqual(@as(u32, if (interrupted) 2 else 1), scenario.connections);
    try std.testing.expectEqual(@as(u32, if (mode == .lost_reply or mode == .pipeline_cut) 2 else 1), scenario.executed);
    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
    try sim.control.checkResources();
    return allocator.dupe(u8, world.traceBytes());
}

fn expectReplay(mode: Mode) !void {
    for (0..4) |seed| {
        const first = try run(std.testing.allocator, seed, mode);
        defer std.testing.allocator.free(first);
        const second = try run(std.testing.allocator, seed, mode);
        defer std.testing.allocator.free(second);
        try std.testing.expectEqualStrings(first, second);
    }
}

test "redis command errors preserve a healthy pooled connection" {
    try expectReplay(.normal);
}
test "redis bytewise fragmented replies replay exactly" {
    try expectReplay(.fragmented);
}
test "redis lost INCR reply causes automatic reexecution" {
    try expectReplay(.lost_reply);
}
test "redis disabling retries exposes ambiguous failure and pool recovers" {
    try expectReplay(.no_retry);
}
test "redis truncated pipeline discards connection and pool recovers" {
    try expectReplay(.pipeline_cut);
}
