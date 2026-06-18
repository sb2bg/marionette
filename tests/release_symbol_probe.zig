//! Production-only binary used by the release symbol check.

const std = @import("std");
const mar = @import("marionette");

const Message = struct {
    value: u8,
};

pub fn main(init: std.process.Init) !void {
    var production = try mar.Production.init(.{
        .allocator = init.gpa,
        .root_dir = std.Io.Dir.cwd(),
        .io = init.io,
    });
    defer production.deinit();

    const peers = [_]mar.ProductionPeer{
        .{ .id = 0, .address = "127.0.0.1:0" },
        .{ .id = 1, .address = "127.0.0.1:1" },
    };
    var endpoints = try production.endpoints(Message, 2, .{
        .first_node = 0,
        .peers = &peers,
    });

    try endpoints[0].send(1, .{ .value = 42 });
    const received = (try endpoints[1].receive()) orelse return error.MissingMessage;
    if (received.from != 0 or received.message.value != 42) return error.BadMessage;

    const env = production.env();
    if (try env.buggify(.release_probe, .always())) return error.ProductionBuggifyFired;
    _ = env.clock.now();
    _ = try env.random.randomU64();
}
