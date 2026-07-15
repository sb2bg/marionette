//! Tiny database-over-message-endpoint example.
//!
//! This intentionally uses a trivial binary wire format. The point is the
//! pattern: the app owns its encoding and decodes typed requests and
//! responses at the edge, while the endpoint moves an owned, value-only
//! message between nodes deterministically.

const std = @import("std");
const mar = @import("marionette");

const server_node: mar.NodeId = 0;
const client_node: mar.NodeId = 1;
const max_frame_len = 9;

const WireMessage = struct {
    len: u8,
    data: [max_frame_len]u8,

    fn init(len: u8) WireMessage {
        return .{ .len = len, .data = @splat(0) };
    }

    fn bytes(self: *const WireMessage) []const u8 {
        return self.data[0..self.len];
    }
};

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

fn encodeRequest(request: Request) WireMessage {
    var message = WireMessage.init(if (request == .insert) 9 else 1);
    message.data[0] = @intFromEnum(std.meta.activeTag(request));
    if (request == .insert) {
        std.mem.writeInt(i64, message.data[1..][0..8], request.insert, .little);
    }
    return message;
}

fn decodeRequest(bytes: []const u8) !Request {
    if (bytes.len == 0) return error.InvalidRequest;
    return switch (try decodeTag(RequestTag, bytes[0])) {
        .ping => if (bytes.len == 1) .ping else error.InvalidRequest,
        .insert => if (bytes.len == 9) .{ .insert = std.mem.readInt(i64, bytes[1..][0..8], .little) } else error.InvalidRequest,
        .select_value => if (bytes.len == 1) .select_value else error.InvalidRequest,
    };
}

fn encodeResponse(response: Response) WireMessage {
    var message = WireMessage.init(if (response == .row) 9 else 1);
    message.data[0] = @intFromEnum(std.meta.activeTag(response));
    if (response == .row) {
        std.mem.writeInt(i64, message.data[1..][0..8], response.row, .little);
    }
    return message;
}

fn decodeResponse(bytes: []const u8) !Response {
    if (bytes.len == 0) return error.InvalidResponse;
    return switch (try decodeTag(ResponseTag, bytes[0])) {
        .pong => if (bytes.len == 1) .pong else error.InvalidResponse,
        .insert_one => if (bytes.len == 1) .insert_one else error.InvalidResponse,
        .row => if (bytes.len == 9) .{ .row = std.mem.readInt(i64, bytes[1..][0..8], .little) } else error.InvalidResponse,
        .empty => if (bytes.len == 1) .empty else error.InvalidResponse,
    };
}

const Server = struct {
    db: Db = .{},
    endpoint: mar.Endpoint(WireMessage),

    /// Handle the next pending request, if any. Returns whether one arrived.
    fn step(self: *Server) !bool {
        const envelope = (try self.endpoint.receive()) orelse return false;

        const request = try decodeRequest(envelope.message.bytes());
        const response = self.db.execute(request);

        try self.endpoint.send(envelope.from, encodeResponse(response));
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

    var server = Server{ .endpoint = try sim.endpoint(WireMessage, server_node) };
    const client = try sim.endpoint(WireMessage, client_node);

    try expectResponse(.pong, try roundTrip(&server, client, .ping));
    try expectResponse(.insert_one, try roundTrip(&server, client, .{ .insert = 41 }));
    try expectResponse(.{ .row = 41 }, try roundTrip(&server, client, .select_value));

    return try allocator.dupe(u8, world.traceBytes());
}

fn roundTrip(server: *Server, client: mar.Endpoint(WireMessage), request: Request) !Response {
    try client.send(server_node, encodeRequest(request));
    if (!try server.step()) return error.MissingRequest;

    const envelope = (try client.receive()) orelse return error.MissingResponse;

    return try decodeResponse(envelope.message.bytes());
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

test "toy database: typed protocol over owned messages" {
    const trace = try runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(trace);

    try std.testing.expect(std.mem.indexOf(u8, trace, "network.send") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "network.deliver") != null);
}
