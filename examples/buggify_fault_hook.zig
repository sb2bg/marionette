//! Current BUGGIFY shape: Marionette decides whether a hook fires; user code
//! owns the domain-specific fault behavior.

const std = @import("std");
const mar = @import("marionette");

pub const SendError = error{
    PacketDropped,
};

/// Send one packet through an environment-provided clock, random source, and
/// fault hook.
pub fn sendPacket(env: anytype, packet_id: u64) !void {
    const latency_ns = try env.random().intLessThan(mar.Duration, 1_000);
    env.clock().sleep(latency_ns);

    if (try env.buggify(.drop_packet, .percent(20))) {
        return SendError.PacketDropped;
    }

    _ = packet_id;
}

/// Run the example in simulation and return the replay trace.
pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var world = try mar.World.init(allocator, .{ .seed = seed });
    defer world.deinit();

    var env = mar.SimulationEnv.init(&world);
    sendPacket(&env, 42) catch |err| switch (err) {
        SendError.PacketDropped => {},
        else => return err,
    };

    return allocator.dupe(u8, world.traceBytes());
}

test "buggify fault hook is replay-visible" {
    const trace = try runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(trace);

    try std.testing.expect(std.mem.indexOf(u8, trace, "world.random_int_less_than") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "buggify hook=drop_packet rate=20/100 roll=") != null);
}
