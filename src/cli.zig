//! Reproduce failures without editing code.
//!
//! A downstream project builds a tiny executable around its `mar.Harness` and
//! calls `run` from `main` with its own allocator, `std.Io`, arguments, and
//! output writer:
//!
//! ```zig
//! pub fn main(init: std.process.Init) !void {
//!     const args = try init.minimal.args.toSlice(init.arena.allocator());
//!     var buffer: [4096]u8 = undefined;
//!     var stdout = std.Io.File.stdout().writer(init.io, &buffer);
//!     const code = try mar.cli.run(MyHarness, init.gpa, init.io, args[1..], identity, &stdout.interface);
//!     try stdout.interface.flush();
//!     if (code != 0) std.process.exit(code);
//! }
//! ```
//!
//! Commands:
//!
//!   rerun <seed> [--trace]               run one seed, as a fuzz or campaign
//!                                         failure reported it
//!   replay <capsule.json> [--trace]      exact-replay a retained capsule
//!   reduce <capsule.json> [--attempts N] reduce a capsule from scratch
//!
//! Any command accepts `--history <focus>`, where focus is `node:<id>`,
//! `op:<id>`, `path:<path>`, or `fault:<id>`, to print only the events that
//! name it. Failures print a diagnosis after their summary.
//!
//! Exit codes: 0 when the run passed or the capsule reproduced, 1 when a rerun
//! failed or a replay diverged, 2 for usage errors.

const std = @import("std");

const diagnosis = @import("diagnosis.zig");
const replay_module = @import("replay.zig");
const run_types = @import("run_types.zig");
const seed_module = @import("seed.zig");

pub const Error = error{OutOfMemory} || std.Io.Writer.Error;

pub fn run(
    comptime H: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    identity: replay_module.Identity,
    out: *std.Io.Writer,
) !u8 {
    if (args.len < 2) return usage(out);
    const command = args[0];
    var trace = false;
    var history: ?diagnosis.Focus = null;
    var attempts: usize = 256;
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--trace")) {
            trace = true;
        } else if (std.mem.eql(u8, arg, "--history") and index + 1 < args.len) {
            index += 1;
            history = diagnosis.Focus.parse(args[index]) catch return usage(out);
        } else if (std.mem.eql(u8, arg, "--attempts") and index + 1 < args.len) {
            index += 1;
            attempts = std.fmt.parseInt(usize, args[index], 10) catch return usage(out);
        } else return usage(out);
    }

    if (std.mem.eql(u8, command, "rerun")) {
        const seed = seed_module.parseSeed(args[1]) catch return usage(out);
        var report = try H.run(allocator, .{ .seed = seed });
        defer report.deinit();
        try writeReport(out, &report, trace, history);
        return if (report == .passed) 0 else 1;
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, args[1], allocator, .limited(256 * 1024 * 1024)) catch |err| {
        try out.print("marionette: cannot read {s}: {s}\n", .{ args[1], @errorName(err) });
        return 2;
    };
    defer allocator.free(bytes);
    var capsule = replay_module.Capsule.decode(allocator, bytes) catch |err| {
        try out.print("marionette: invalid capsule {s}: {s}\n", .{ args[1], @errorName(err) });
        return 2;
    };
    defer capsule.deinit();

    if (std.mem.eql(u8, command, "replay")) {
        var report = H.replay(allocator, &capsule, identity) catch |err| {
            try out.print("marionette: replay rejected: {s}\n", .{@errorName(err)});
            return 1;
        };
        defer report.deinit();
        try writeReport(out, &report, trace, history);
        const diverged = switch (report) {
            .passed => false,
            .failed => |failure| failure.kind == .replay_diverged or failure.replay_divergence != null,
        };
        return if (diverged) 1 else 0;
    }
    if (std.mem.eql(u8, command, "reduce")) {
        var reduced = H.reduceCapsule(allocator, &capsule, identity, .{ .max_attempts = attempts }) catch |err| {
            try out.print("marionette: reduction rejected: {s}\n", .{@errorName(err)});
            return 1;
        };
        defer reduced.deinit();
        try out.print("marionette.reduce attempts={} remaining_groups={} minimized={}\n", .{
            reduced.attempts,
            reduced.remaining_groups,
            reduced.minimized != null,
        });
        try writeReport(out, reduced.report(), trace, history);
        return 0;
    }
    return usage(out);
}

fn writeReport(out: *std.Io.Writer, report: *const run_types.RunReport, trace: bool, history: ?diagnosis.Focus) !void {
    const bytes = switch (report.*) {
        .passed => |passed| bytes: {
            try out.print("marionette: passed seed={} events={}\n", .{ passed.options.seed, passed.event_count });
            break :bytes passed.trace;
        },
        .failed => |failure| bytes: {
            try failure.writeSummary(out);
            try failure.writeDiagnosis(out);
            break :bytes failure.first_trace;
        },
    };
    if (history) |focus| {
        const count = try diagnosis.writeHistory(out, bytes, focus);
        try out.print("history: {} events\n", .{count});
    }
    if (trace) try out.writeAll(bytes);
}

fn usage(out: *std.Io.Writer) !u8 {
    try out.writeAll(
        \\usage: <harness> rerun <seed> [--trace] [--history <focus>]
        \\       <harness> replay <capsule.json> [--trace] [--history <focus>]
        \\       <harness> reduce <capsule.json> [--attempts N] [--trace] [--history <focus>]
        \\focus: node:<id> | op:<id> | path:<path> | fault:<id>
        \\
    );
    return 2;
}
