//! Subprocess checker for the fiber overflow diagnostics. Spawns the crash
//! binary (argv[1]) in the given mode (argv[2]), captures stderr, and
//! asserts the diagnostic contract:
//!
//! - `overflow`: the child dies to a signal and stderr carries the
//!   marionette diagnostic naming the task id, process id, configured stack
//!   size, and the `task_stack_size` fix.
//! - `non-fiber-fault`: the child dies abnormally and stderr carries no
//!   marionette diagnostic, proving non-guard faults fall through to the
//!   previous signal behavior.

const std = @import("std");

const overflow_needles = [_][]const u8{
    "marionette: fiber stack overflow",
    "task 0",
    "process 0",
    "128 KiB",
    "task_stack_size",
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const crash_exe = args.next() orelse return error.MissingCrashExePath;
    const mode = args.next() orelse return error.MissingMode;

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ crash_exe, mode },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });

    var transfer_buffer: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(init.io, &transfer_buffer);
    var output_buffer: [64 * 1024]u8 = undefined;
    const output_len = try stderr_reader.interface.readSliceShort(&output_buffer);
    const output = output_buffer[0..output_len];

    const term = try child.wait(init.io);
    const died_abnormally = switch (term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (!died_abnormally) {
        std.debug.print("crash child exited cleanly in mode {s}; stderr:\n{s}\n", .{ mode, output });
        return error.CrashChildExitedCleanly;
    }

    if (std.mem.eql(u8, mode, "overflow")) {
        for (overflow_needles) |needle| {
            if (std.mem.indexOf(u8, output, needle) == null) {
                std.debug.print("missing needle \"{s}\" in overflow stderr:\n{s}\n", .{ needle, output });
                return error.MissingDiagnosticNeedle;
            }
        }
        return;
    }

    if (std.mem.eql(u8, mode, "non-fiber-fault")) {
        if (std.mem.indexOf(u8, output, "marionette: fiber stack overflow") != null) {
            std.debug.print("non-fiber fault produced a fiber diagnostic:\n{s}\n", .{output});
            return error.UnexpectedDiagnostic;
        }
        return;
    }

    return error.UnknownMode;
}
