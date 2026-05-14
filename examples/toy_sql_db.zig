//! Tiny SQL-over-byte-transport example.
//!
//! This is intentionally not a SQL implementation. It shows the intended user
//! pattern: a protocol adapter wraps `mar.ByteTransport`, while the database
//! service only sees parsed requests and typed responses.

const std = @import("std");
const mar = @import("marionette");

const server_node: mar.NodeId = 0;
const client_node: mar.NodeId = 1;

const Db = struct {
    value: ?i64 = null,

    fn execute(self: *Db, request: Request) Response {
        switch (request) {
            .ping => return .{ .ok = .pong },
            .insert => |value| {
                self.value = value;
                return .{ .ok = .insert_one };
            },
            .select_value => {
                if (self.value) |value| return .{ .row = value };
                return .{ .err = .empty };
            },
        }
    }
};

const Request = union(enum) {
    ping,
    insert: i64,
    select_value,
};

const Response = union(enum) {
    ok: Ok,
    row: i64,
    err: Err,

    const Ok = enum {
        pong,
        insert_one,
    };

    const Err = enum {
        empty,
    };
};

const SqlRequest = struct {
    from: mar.NodeId,
    request: Request,
};

const SqlProtocol = struct {
    transport: mar.ByteTransport,

    fn init(transport: mar.ByteTransport) SqlProtocol {
        return .{ .transport = transport };
    }

    fn sendQuery(self: SqlProtocol, to: mar.NodeId, sql: []const u8) !void {
        try self.transport.send(to, sql);
    }

    fn receiveQuery(self: SqlProtocol) !?SqlRequest {
        var message = (try self.transport.receive()) orelse return null;
        defer message.deinit();

        return .{
            .from = message.from(),
            .request = try decodeRequest(message.bytes()),
        };
    }

    fn reply(self: SqlProtocol, to: mar.NodeId, response: Response) !void {
        var buffer: [64]u8 = undefined;
        const bytes = try encodeResponse(&buffer, response);
        try self.transport.send(to, bytes);
    }

    fn receiveResponse(self: SqlProtocol) !?Response {
        var message = (try self.transport.receive()) orelse return null;
        defer message.deinit();

        return try decodeResponse(message.bytes());
    }
};

const Server = struct {
    db: Db = .{},
    protocol: SqlProtocol,

    fn step(self: *Server) !bool {
        const request = (try self.protocol.receiveQuery()) orelse return false;
        const response = self.db.execute(request.request);
        try self.protocol.reply(request.from, response);
        return true;
    }
};

pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var world = try mar.World.init(allocator, .{ .seed = seed });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{
        .nodes = 2,
        .path_capacity = 8,
    } });

    var server = Server{
        .protocol = .init(.init(try sim.byteEndpoint(server_node))),
    };
    const client = SqlProtocol.init(.init(try sim.byteEndpoint(client_node)));

    try expectResponse(.{ .ok = .pong }, try roundTrip(&server, client, "PING"));
    try expectResponse(.{ .ok = .insert_one }, try roundTrip(&server, client, "INSERT INTO kv VALUES 41"));
    try expectResponse(.{ .row = 41 }, try roundTrip(&server, client, "SELECT value FROM kv"));

    return try allocator.dupe(u8, world.traceBytes());
}

fn roundTrip(server: *Server, client: SqlProtocol, sql: []const u8) !Response {
    try client.sendQuery(server_node, sql);
    if (!try server.step()) return error.MissingRequest;
    return (try client.receiveResponse()) orelse error.MissingResponse;
}

fn decodeRequest(sql: []const u8) !Request {
    if (std.mem.eql(u8, sql, "PING")) return .ping;
    if (std.mem.eql(u8, sql, "SELECT value FROM kv")) return .select_value;

    const prefix = "INSERT INTO kv VALUES ";
    if (std.mem.startsWith(u8, sql, prefix)) {
        const value = try std.fmt.parseInt(i64, sql[prefix.len..], 10);
        return .{ .insert = value };
    }

    return error.UnsupportedSql;
}

fn encodeResponse(buffer: []u8, response: Response) ![]const u8 {
    return switch (response) {
        .ok => |ok| try std.fmt.bufPrint(buffer, "OK {s}", .{encodeOk(ok)}),
        .row => |value| try std.fmt.bufPrint(buffer, "ROW {}", .{value}),
        .err => |err| try std.fmt.bufPrint(buffer, "ERR {s}", .{encodeErr(err)}),
    };
}

fn decodeResponse(bytes: []const u8) !Response {
    if (std.mem.eql(u8, bytes, "OK PONG")) return .{ .ok = .pong };
    if (std.mem.eql(u8, bytes, "OK INSERT 1")) return .{ .ok = .insert_one };
    if (std.mem.eql(u8, bytes, "ERR EMPTY")) return .{ .err = .empty };
    if (std.mem.startsWith(u8, bytes, "ROW ")) {
        return .{ .row = try std.fmt.parseInt(i64, bytes[4..], 10) };
    }
    return error.InvalidResponse;
}

fn encodeOk(ok: Response.Ok) []const u8 {
    return switch (ok) {
        .pong => "PONG",
        .insert_one => "INSERT 1",
    };
}

fn encodeErr(err: Response.Err) []const u8 {
    return switch (err) {
        .empty => "EMPTY",
    };
}

fn expectResponse(expected: Response, actual: Response) !void {
    switch (expected) {
        .ok => |expected_ok| switch (actual) {
            .ok => |actual_ok| try std.testing.expectEqual(expected_ok, actual_ok),
            else => return error.UnexpectedResponse,
        },
        .row => |expected_value| switch (actual) {
            .row => |actual_value| try std.testing.expectEqual(expected_value, actual_value),
            else => return error.UnexpectedResponse,
        },
        .err => |expected_err| switch (actual) {
            .err => |actual_err| try std.testing.expectEqual(expected_err, actual_err),
            else => return error.UnexpectedResponse,
        },
    }
}

test "toy sql db: protocol adapter wraps byte transport" {
    const trace = try runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(trace);

    try std.testing.expect(std.mem.indexOf(u8, trace, "network.send") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "network.deliver") != null);
}
