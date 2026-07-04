//! Crash-on-purpose binary for the fiber overflow diagnostics subprocess
//! test. Mode `overflow` runs a simulated task that recurses until it hits
//! its guard region: the expected outcome is the marionette diagnostic on
//! stderr followed by fatal signal termination. Mode `non-fiber-fault`
//! spawns one task (so the handler is installed and a guard is registered),
//! then faults outside every guard region: the expected outcome is fatal
//! termination with no marionette diagnostic, proving non-fiber faults
//! chain through untouched.

const std = @import("std");
const mar = @import("marionette");

const configured_stack_size = 128 * 1024;

var sink: u64 = 0;

fn blowStack(depth: u64) u64 {
    var pad: [4096]u8 = undefined;
    pad[0] = @truncate(depth);
    std.mem.doNotOptimizeAway(&pad);
    return pad[depth % pad.len] + blowStack(depth + 1);
}

fn overflowTask() void {
    sink +%= blowStack(0);
}

fn noopTask() void {
    sink +%= 1;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const mode = args.next() orelse return error.MissingMode;

    var world = try mar.World.init(init.gpa, .{ .seed = 0xC0FFEE });
    defer world.deinit();

    const sim = try world.simulate(.{
        .task_stack_size = configured_stack_size,
        .network = .{ .nodes = 1 },
    });
    const io = (try sim.envForNode(0)).io();

    if (std.mem.eql(u8, mode, "overflow")) {
        var future = try std.Io.concurrent(io, overflowTask, .{});
        future.await(io);
        return error.OverflowDidNotFault;
    }

    if (std.mem.eql(u8, mode, "non-fiber-fault")) {
        var future = try std.Io.concurrent(io, noopTask, .{});
        future.await(io);
        // Fault well outside any guard region, from the main context. Page
        // zero is unmapped on every supported target (mmap_min_addr on
        // Linux, __PAGEZERO on macOS).
        @as(*volatile u8, @ptrFromInt(4)).* = 1;
        return error.NonFiberFaultDidNotFault;
    }

    return error.UnknownMode;
}
