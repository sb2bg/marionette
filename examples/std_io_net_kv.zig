//! A production-shaped, fixed-frame KV protocol built only on `std.Io.net`.
//!
//! Marionette-specific scheduling, faults, tracing, and checks live in the
//! validation harness. This file intentionally imports only `std`.

const std = @import("std");

const Io = std.Io;

const request_magic: u32 = 0x4d4e4b51; // MNKQ
const response_magic: u32 = 0x4d4e4b52; // MNKR
const request_size = 32;
const response_size = 32;
const max_entries = 16;
const max_cached_requests = 32;

pub const ServerMode = enum {
    deduplicate,
    apply_every_put,
};

pub const Response = struct {
    request_id: u64,
    value: i64,
    revision: u64,
    duplicate: bool,
};

const RequestKind = enum(u8) {
    put = 1,
    get = 2,
};

const Request = struct {
    kind: RequestKind,
    request_id: u64,
    key: u64,
    value: i64,
};

const Entry = struct {
    key: u64,
    value: i64,
};

const CachedResponse = struct {
    request_id: u64,
    response: Response,
};

pub const Server = struct {
    mode: ServerMode,
    entries: [max_entries]Entry = undefined,
    entry_count: usize = 0,
    cached: [max_cached_requests]CachedResponse = undefined,
    cached_count: usize = 0,
    revision: u64 = 0,
    applied_puts: usize = 0,

    pub fn init(mode: ServerMode) Server {
        return .{ .mode = mode };
    }

    pub fn serveOne(self: *Server, io: Io, stream: Io.net.Stream) !void {
        var request_bytes: [request_size]u8 = undefined;
        try readExact(io, stream, &request_bytes);
        const request = try decodeRequest(&request_bytes);

        const response = try self.handle(request);
        var response_bytes: [response_size]u8 = undefined;
        encodeResponse(&response_bytes, response);
        try writeAll(io, stream, &response_bytes);
    }

    pub fn get(self: *const Server, key: u64) ?i64 {
        for (self.entries[0..self.entry_count]) |entry| {
            if (entry.key == key) return entry.value;
        }
        return null;
    }

    fn handle(self: *Server, request: Request) !Response {
        switch (request.kind) {
            .put => {
                if (self.mode == .deduplicate) {
                    if (self.cachedResponse(request.request_id)) |cached| {
                        var duplicate = cached;
                        duplicate.duplicate = true;
                        return duplicate;
                    }
                }

                try self.put(request.key, request.value);
                self.revision += 1;
                self.applied_puts += 1;

                const response: Response = .{
                    .request_id = request.request_id,
                    .value = request.value,
                    .revision = self.revision,
                    .duplicate = false,
                };
                try self.cacheResponse(response);
                return response;
            },
            .get => return .{
                .request_id = request.request_id,
                .value = self.get(request.key) orelse return error.KeyNotFound,
                .revision = self.revision,
                .duplicate = false,
            },
        }
    }

    fn put(self: *Server, key: u64, value: i64) !void {
        for (self.entries[0..self.entry_count]) |*entry| {
            if (entry.key != key) continue;
            entry.value = value;
            return;
        }
        if (self.entry_count == self.entries.len) return error.StoreFull;
        self.entries[self.entry_count] = .{ .key = key, .value = value };
        self.entry_count += 1;
    }

    fn cachedResponse(self: *const Server, request_id: u64) ?Response {
        for (self.cached[0..self.cached_count]) |cached| {
            if (cached.request_id == request_id) return cached.response;
        }
        return null;
    }

    fn cacheResponse(self: *Server, response: Response) !void {
        if (self.cached_count == self.cached.len) return error.RequestCacheFull;
        self.cached[self.cached_count] = .{
            .request_id = response.request_id,
            .response = response,
        };
        self.cached_count += 1;
    }
};

pub const Client = struct {
    io: Io,
    stream: Io.net.Stream,

    pub fn connect(io: Io, address: Io.net.IpAddress) !Client {
        return .{
            .io = io,
            .stream = try address.connect(io, .{
                .mode = .stream,
                .protocol = .tcp,
            }),
        };
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(self.io);
        self.* = undefined;
    }

    pub fn put(self: *Client, request_id: u64, key: u64, value: i64) !Response {
        return try self.request(.{
            .kind = .put,
            .request_id = request_id,
            .key = key,
            .value = value,
        });
    }

    pub fn get(self: *Client, request_id: u64, key: u64) !Response {
        return try self.request(.{
            .kind = .get,
            .request_id = request_id,
            .key = key,
            .value = 0,
        });
    }

    fn request(self: *Client, value: Request) !Response {
        var request_bytes: [request_size]u8 = undefined;
        encodeRequest(&request_bytes, value);
        try writeAll(self.io, self.stream, &request_bytes);

        var response_bytes: [response_size]u8 = undefined;
        try readExact(self.io, self.stream, &response_bytes);
        const response = try decodeResponse(&response_bytes);
        if (response.request_id != value.request_id) return error.ResponseRequestMismatch;
        return response;
    }
};

fn readExact(io: Io, stream: Io.net.Stream, dest: []u8) !void {
    var reader = stream.reader(io, &.{});
    reader.interface.readSliceAll(dest) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse error.Unexpected,
        else => return err,
    };
}

fn writeAll(io: Io, stream: Io.net.Stream, bytes: []const u8) !void {
    var writer = stream.writer(io, &.{});
    writer.interface.writeAll(bytes) catch |err| switch (err) {
        error.WriteFailed => return writer.err orelse error.Unexpected,
    };
}

fn encodeRequest(dest: *[request_size]u8, request: Request) void {
    @memset(dest, 0);
    std.mem.writeInt(u32, dest[0..4], request_magic, .little);
    dest[4] = @intFromEnum(request.kind);
    std.mem.writeInt(u64, dest[8..16], request.request_id, .little);
    std.mem.writeInt(u64, dest[16..24], request.key, .little);
    std.mem.writeInt(i64, dest[24..32], request.value, .little);
}

fn decodeRequest(bytes: *const [request_size]u8) !Request {
    if (std.mem.readInt(u32, bytes[0..4], .little) != request_magic) {
        return error.InvalidRequestMagic;
    }
    const kind: RequestKind = switch (bytes[4]) {
        @intFromEnum(RequestKind.put) => .put,
        @intFromEnum(RequestKind.get) => .get,
        else => return error.InvalidRequestKind,
    };
    return .{
        .kind = kind,
        .request_id = std.mem.readInt(u64, bytes[8..16], .little),
        .key = std.mem.readInt(u64, bytes[16..24], .little),
        .value = std.mem.readInt(i64, bytes[24..32], .little),
    };
}

fn encodeResponse(dest: *[response_size]u8, response: Response) void {
    @memset(dest, 0);
    std.mem.writeInt(u32, dest[0..4], response_magic, .little);
    dest[4] = @intFromBool(response.duplicate);
    std.mem.writeInt(u64, dest[8..16], response.request_id, .little);
    std.mem.writeInt(i64, dest[16..24], response.value, .little);
    std.mem.writeInt(u64, dest[24..32], response.revision, .little);
}

fn decodeResponse(bytes: *const [response_size]u8) !Response {
    if (std.mem.readInt(u32, bytes[0..4], .little) != response_magic) {
        return error.InvalidResponseMagic;
    }
    const duplicate = switch (bytes[4]) {
        0 => false,
        1 => true,
        else => return error.InvalidDuplicateFlag,
    };
    return .{
        .request_id = std.mem.readInt(u64, bytes[8..16], .little),
        .value = std.mem.readInt(i64, bytes[16..24], .little),
        .revision = std.mem.readInt(u64, bytes[24..32], .little),
        .duplicate = duplicate,
    };
}

test "fixed-frame request and response codecs round trip" {
    const request: Request = .{
        .kind = .put,
        .request_id = 7,
        .key = 11,
        .value = 41,
    };
    var request_bytes: [request_size]u8 = undefined;
    encodeRequest(&request_bytes, request);
    try std.testing.expectEqualDeep(request, try decodeRequest(&request_bytes));

    const response: Response = .{
        .request_id = 7,
        .value = 41,
        .revision = 1,
        .duplicate = true,
    };
    var response_bytes: [response_size]u8 = undefined;
    encodeResponse(&response_bytes, response);
    try std.testing.expectEqualDeep(response, try decodeResponse(&response_bytes));
}
