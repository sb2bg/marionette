//! Unmodified karlseguin/pg.zig against a scripted PostgreSQL protocol peer.
//! Exercises cleartext password auth, simple-query affected counts, SQL error
//! recovery on the same connection, fragmented responses, and truncated frames.
//! This is client validation, not a PostgreSQL implementation. TLS and native
//! socket keepalive are disabled; upstream query timeouts are not implemented.
const std = @import("std");
const mar = @import("marionette");
const pg = @import("pg");
const Io = std.Io;
const address = Io.net.IpAddress.parseIp4("10.0.0.1", 5432) catch unreachable;
const Mode = enum { normal, fragmented, truncated };

const Scenario = struct {
    allocator: std.mem.Allocator,
    control: mar.Control,
    server_io: Io,
    client_io: Io,
    mode: Mode,
    ready: u32 = 0,

    fn frame(reader: *Io.Reader, buffer: []u8) ![]const u8 {
        const size = try reader.takeInt(u32, .big);
        if (size < 4 or size - 4 > buffer.len) return error.InvalidFrame;
        const body = buffer[0 .. size - 4];
        try reader.readSliceAll(body);
        return body;
    }

    fn expectMessage(reader: *Io.Reader, tag: u8, expected: []const u8) !void {
        try std.testing.expectEqual(tag, try reader.takeByte());
        var buffer: [1024]u8 = undefined;
        try std.testing.expectEqualStrings(expected, try frame(reader, &buffer));
    }

    fn send(self: *Scenario, writer: *Io.Writer, tag: u8, body: []const u8) !void {
        var buffer: [1024]u8 = undefined;
        buffer[0] = tag;
        std.mem.writeInt(u32, buffer[1..5], @intCast(body.len + 4), .big);
        @memcpy(buffer[5..][0..body.len], body);
        const bytes = buffer[0 .. 5 + body.len];
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

    fn server(self: *Scenario) !void {
        var listener = try address.listen(self.server_io, .{});
        defer listener.deinit(self.server_io);
        self.ready = 1;
        self.server_io.futexWake(u32, &self.ready, 1);
        const stream = try listener.accept(self.server_io);
        defer stream.close(self.server_io);
        var read_buffer: [1024]u8 = undefined;
        var write_buffer: [1024]u8 = undefined;
        var reader = stream.reader(self.server_io, &read_buffer);
        var writer = stream.writer(self.server_io, &write_buffer);
        const r = &reader.interface;
        const w = &writer.interface;
        var startup_buffer: [1024]u8 = undefined;
        const startup = try frame(r, &startup_buffer);
        try std.testing.expect(startup.len >= 4);
        try std.testing.expectEqual(@as(u32, 196608), std.mem.readInt(u32, startup[0..4], .big));
        try std.testing.expect(std.mem.indexOf(u8, startup[4..], "user\x00marionette\x00") != null);
        try std.testing.expect(std.mem.indexOf(u8, startup[4..], "database\x00validation\x00") != null);
        try self.send(w, 'R', &.{ 0, 0, 0, 3 });
        try expectMessage(r, 'p', "secret\x00");
        try self.send(w, 'R', &.{ 0, 0, 0, 0 });
        try self.send(w, 'Z', "I");
        self.control.record("pg.server.authenticated", .{});
        try expectMessage(r, 'Q', "update items set value = 7\x00");
        if (self.mode == .truncated) {
            // CommandComplete advertises nine body bytes but closes after two.
            try w.writeAll("C\x00\x00\x00\x0dUP");
            try w.flush();
            self.control.record("pg.server.truncated", .{});
            return;
        }
        try self.send(w, 'C', "UPDATE 3\x00");
        try self.send(w, 'Z', "I");
        try expectMessage(r, 'Q', "invalid sql\x00");
        try self.send(w, 'E', "SERROR\x00C42601\x00Msyntax error\x00\x00");
        try self.send(w, 'Z', "I");
        try expectMessage(r, 'Q', "delete from items\x00");
        try self.send(w, 'C', "DELETE 2\x00");
        try self.send(w, 'Z', "I");
        try expectMessage(r, 'X', "");
    }

    fn client(self: *Scenario) !void {
        while (self.ready == 0) try self.server_io.futexWait(u32, &self.ready, 0);
        var conn = try pg.Conn.openAndAuth(self.client_io, self.allocator, .{
            .host = "10.0.0.1",
            .port = 5432,
            .keepalive = false,
            .read_buffer = 32,
        }, .{ .username = "marionette", .database = "validation", .password = "secret" });
        defer conn.deinit();
        if (self.mode == .truncated) {
            try std.testing.expectError(error.EndOfStream, conn.exec("update items set value = 7", .{}));
            self.control.record("pg.client.interrupted", .{});
            return;
        }
        try std.testing.expectEqual(@as(?i64, 3), try conn.exec("update items set value = 7", .{}));
        try std.testing.expectError(error.PG, conn.exec("invalid sql", .{}));
        try std.testing.expect(conn.err != null);
        try std.testing.expectEqualStrings("42601", conn.err.?.code);
        try std.testing.expectEqual(@as(?i64, 2), try conn.exec("delete from items", .{}));
        self.control.record("pg.client.recovered affected=2", .{});
    }
};

fn App(comptime mode: Mode) type {
    return struct {
        scenario: Scenario,

        fn init(sim: mar.Sim) !@This() {
            try sim.control.network.setLatency(.{ .min_latency_ns = 30 });
            return .{ .scenario = .{
                .allocator = sim.control.harnessAllocator(),
                .control = sim.control,
                .server_io = (try sim.envForNode(0)).io(),
                .client_io = (try sim.envForNode(1)).io(),
                .mode = mode,
            } };
        }

        /// Both tasks return their errors through their futures, so a
        /// protocol mismatch fails the run with a report, not a panic.
        fn run(case: *mar.SimCase(@This())) !void {
            const scenario = &case.app.scenario;
            var server = try Io.concurrent(scenario.server_io, Scenario.server, .{scenario});
            defer server.cancel(scenario.server_io) catch {};
            var client = try Io.concurrent(scenario.client_io, Scenario.client, .{scenario});
            defer client.cancel(scenario.client_io) catch {};
            try client.await(scenario.client_io);
            try server.await(scenario.server_io);
            if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;
        }
    };
}

fn PgHarness(comptime mode: Mode) type {
    return mar.Harness(.{
        .init = App(mode).init,
        .scenario = App(mode).run,
        .simulate = mar.World.SimulateOptions{ .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 32 } },
        .name = "pg." ++ @tagName(mode),
    });
}

/// Four seeds, each executed twice by the runner and compared exactly.
fn expectReplay(comptime mode: Mode) !void {
    try PgHarness(mode).fuzz(std.testing.allocator, .{ .tick_ns = 10 }, .{ .seeds = 4 });
}

test "pg authentication, affected counts, and SQL error recovery replay exactly" {
    try expectReplay(.normal);
}

test "pg handles bytewise fragmented responses and replays exactly" {
    try expectReplay(.fragmented);
}

test "pg rejects a truncated response with EndOfStream and replays exactly" {
    try expectReplay(.truncated);
}
