//! Tiny database-over-byte-transport example.
//!
//! This intentionally uses a trivial binary wire format. The point is the
//! transport pattern: codecs adapt bytes to typed requests and responses, while
//! the database service only sees those typed values.

const std = @import("std");
const mar = @import("marionette");

const server_node: mar.NodeId = 0;
const client_node: mar.NodeId = 1;

const Db = struct {
    value: ?i64 = null,

    fn execute(self: *Db, request: Request) Response {
        switch (request) {
            .ping => return .pong,
            .insert => |value| {
                self.value = value;
                return .insert_one;
            },
            .select_value => {
                if (self.value) |value| return .{ .row = value };
                return .empty;
            },
        }
    }
};

const RequestTag = enum(u8) {
    ping,
    insert,
    select_value,
};

const Request = union(RequestTag) {
    ping,
    insert: i64,
    select_value,
};

const ResponseTag = enum(u8) {
    pong,
    insert_one,
    row,
    empty,
};

const Response = union(ResponseTag) {
    pong,
    insert_one,
    row: i64,
    empty,
};

const ClientCodec = struct {
    pub const Send = Request;
    pub const Recv = Response;
    pub const recv_lifetime: mar.CodecRecvLifetime = .owned;

    pub fn encodedLen(request: Send) !usize {
        return if (request == .insert) 9 else 1;
    }

    pub fn encode(buffer: []u8, request: Send) ![]const u8 {
        const len = try encodedLen(request);
        if (len > buffer.len) return error.NoSpaceLeft;
        buffer[0] = @intFromEnum(std.meta.activeTag(request));
        if (request == .insert) std.mem.writeInt(i64, buffer[1..][0..8], request.insert, .little);
        return buffer[0..len];
    }

    pub fn decode(bytes: []const u8) !Recv {
        if (bytes.len == 0) return error.InvalidResponse;
        return switch (try decodeTag(ResponseTag, bytes[0])) {
            .pong => if (bytes.len == 1) .pong else error.InvalidResponse,
            .insert_one => if (bytes.len == 1) .insert_one else error.InvalidResponse,
            .row => if (bytes.len == 9) .{ .row = std.mem.readInt(i64, bytes[1..][0..8], .little) } else error.InvalidResponse,
            .empty => if (bytes.len == 1) .empty else error.InvalidResponse,
        };
    }
};

const ServerCodec = struct {
    pub const Send = Response;
    pub const Recv = Request;
    pub const recv_lifetime: mar.CodecRecvLifetime = .owned;

    pub fn encodedLen(response: Send) !usize {
        return if (response == .row) 9 else 1;
    }

    pub fn encode(buffer: []u8, response: Send) ![]const u8 {
        const len = try encodedLen(response);
        if (len > buffer.len) return error.NoSpaceLeft;
        buffer[0] = @intFromEnum(std.meta.activeTag(response));
        if (response == .row) std.mem.writeInt(i64, buffer[1..][0..8], response.row, .little);
        return buffer[0..len];
    }

    pub fn decode(bytes: []const u8) !Recv {
        if (bytes.len == 0) return error.InvalidRequest;
        return switch (try decodeTag(RequestTag, bytes[0])) {
            .ping => if (bytes.len == 1) .ping else error.InvalidRequest,
            .insert => if (bytes.len == 9) .{ .insert = std.mem.readInt(i64, bytes[1..][0..8], .little) } else error.InvalidRequest,
            .select_value => if (bytes.len == 1) .select_value else error.InvalidRequest,
        };
    }
};

const ClientTransport = mar.CodecTransport(ClientCodec);
const ServerTransport = mar.CodecTransport(ServerCodec);

const Server = struct {
    db: Db = .{},
    transport: ServerTransport,

    fn step(self: *Server) !bool {
        return try self.transport.handleNext(self, handleRequest);
    }

    fn handleRequest(self: *Server, from: mar.NodeId, request: Request) !void {
        const response = self.db.execute(request);
        try self.transport.send(from, response);
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
        .transport = .init(.init(try sim.byteEndpoint(server_node))),
    };
    const client = ClientTransport.init(.init(try sim.byteEndpoint(client_node)));

    try expectResponse(.pong, try roundTrip(&server, client, .ping));
    try expectResponse(.insert_one, try roundTrip(&server, client, .{ .insert = 41 }));
    try expectResponse(.{ .row = 41 }, try roundTrip(&server, client, .select_value));

    return try allocator.dupe(u8, world.traceBytes());
}

fn roundTrip(server: *Server, client: ClientTransport, request: Request) !Response {
    try client.send(server_node, request);
    if (!try server.step()) return error.MissingRequest;

    var response = (try client.receive()) orelse return error.MissingResponse;
    defer response.deinit();

    return response.value();
}

fn decodeTag(comptime Tag: type, value: u8) !Tag {
    inline for (std.meta.fields(Tag)) |field| {
        if (field.value == value) return @enumFromInt(value);
    }
    return error.InvalidTag;
}

fn expectResponse(expected: Response, actual: Response) !void {
    switch (expected) {
        .pong, .insert_one, .empty => try std.testing.expectEqual(expected, actual),
        .row => |expected_value| switch (actual) {
            .row => |actual_value| try std.testing.expectEqual(expected_value, actual_value),
            else => return error.UnexpectedResponse,
        },
    }
}

test "toy database: protocol adapter wraps codec transport" {
    const trace = try runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(trace);

    try std.testing.expect(std.mem.indexOf(u8, trace, "network.send") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "network.deliver") != null);
}
