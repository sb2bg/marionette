//! Production-only binary used by the release symbol check.

const std = @import("std");
const mar = @import("marionette");

pub fn main(init: std.process.Init) !void {
    var production = try mar.Production.init(.{
        .allocator = init.gpa,
        .root_dir = std.Io.Dir.cwd(),
        .io = init.io,
    });
    defer production.deinit();

    const env = production.env();
    if (try env.buggify(.release_probe, .always())) return error.ProductionBuggifyFired;
    _ = std.Io.Clock.awake.now(env.io());
    var random_source: std.Random.IoSource = .{ .io = env.io() };
    _ = random_source.interface().int(u64);
}
