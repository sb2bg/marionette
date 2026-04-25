//! CLI entry point for running Marionette examples by seed.

const std = @import("std");
const examples = @import("examples");
const mar = @import("marionette");

const default_seed: u64 = 0xC0FFEE;

const Mode = enum {
    summary,
    trace,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    const exe_name = args.next() orelse "marionette-run";

    var scenario_name: ?[]const u8 = null;
    var seed: u64 = default_seed;
    var mode: Mode = .summary;
    var expect_failure = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--seed")) {
            const seed_text = args.next() orelse return usage(exe_name);
            seed = mar.parseSeed(seed_text) catch return usage(exe_name);
        } else if (std.mem.eql(u8, arg, "--summary")) {
            mode = .summary;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            mode = .trace;
        } else if (std.mem.eql(u8, arg, "--expect-failure")) {
            expect_failure = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage(exe_name);
        } else if (scenario_name == null) {
            scenario_name = arg;
        } else {
            return usage(exe_name);
        }
    }

    const scenario = scenario_name orelse return usage(exe_name);
    try runScenario(allocator, scenario, seed, mode, expect_failure);
}

fn runScenario(
    allocator: std.mem.Allocator,
    scenario: []const u8,
    seed: u64,
    mode: Mode,
    expect_failure: bool,
) !void {
    if (std.mem.eql(u8, scenario, "retry-queue")) {
        const trace = try examples.retry_queue.runScenario(allocator, seed);
        defer allocator.free(trace);
        if (expect_failure) return expectedFailureDidNotHappen();
        try printTraceOrSummary(allocator, trace, mode);
    } else if (std.mem.eql(u8, scenario, "retry-queue-bug")) {
        try printReport(try examples.retry_queue.runBuggyScenario(allocator, seed), expect_failure);
    } else if (std.mem.eql(u8, scenario, "replicated-register")) {
        const trace = try examples.replicated_register.runScenario(allocator, seed);
        defer allocator.free(trace);
        if (expect_failure) return expectedFailureDidNotHappen();
        try printTraceOrSummary(allocator, trace, mode);
    } else if (std.mem.eql(u8, scenario, "replicated-register-bug")) {
        try printReport(try examples.replicated_register.runBuggyScenario(allocator, seed), expect_failure);
    } else if (std.mem.eql(u8, scenario, "replicated-register-partition")) {
        const trace = try examples.replicated_register.runPartitionScenario(allocator, seed);
        defer allocator.free(trace);
        if (expect_failure) return expectedFailureDidNotHappen();
        try printTraceOrSummary(allocator, trace, mode);
    } else if (std.mem.eql(u8, scenario, "replicated-register-conflict")) {
        const trace = try examples.replicated_register.runConflictScenario(allocator, seed);
        defer allocator.free(trace);
        if (expect_failure) return expectedFailureDidNotHappen();
        try printTraceOrSummary(allocator, trace, mode);
    } else {
        std.debug.print("unknown scenario: {s}\n", .{scenario});
        std.process.exit(2);
    }
}

fn printTraceOrSummary(
    allocator: std.mem.Allocator,
    trace: []const u8,
    mode: Mode,
) !void {
    switch (mode) {
        .trace => std.debug.print("{s}", .{trace}),
        .summary => {
            var summary = try mar.summarize(allocator, trace);
            defer summary.deinit();

            var buffer: [16 * 1024]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try summary.writeSummary(&writer);
            std.debug.print("{s}", .{writer.buffered()});
        },
    }
}

fn printReport(report: mar.RunReport, expect_failure: bool) !void {
    var owned_report = report;
    defer owned_report.deinit();

    switch (owned_report) {
        .passed => |passed| {
            std.debug.print(
                "marionette passed unexpectedly: seed={} events={}\n",
                .{ passed.options.seed, passed.event_count },
            );
            if (expect_failure) std.process.exit(1);
        },
        .failed => |failure| {
            var buffer: [4096]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try failure.writeSummary(&writer);
            std.debug.print("{s}", .{writer.buffered()});
            if (!expect_failure) std.process.exit(1);
        },
    }
}

fn expectedFailureDidNotHappen() noreturn {
    std.debug.print("marionette passed unexpectedly with --expect-failure\n", .{});
    std.process.exit(1);
}

fn usage(exe_name: []const u8) noreturn {
    std.debug.print(
        \\usage: {s} <scenario> [--seed <seed>] [--summary|--trace] [--expect-failure]
        \\
        \\scenarios:
        \\  retry-queue
        \\  retry-queue-bug
        \\  replicated-register
        \\  replicated-register-bug
        \\  replicated-register-partition
        \\  replicated-register-conflict
        \\
    ,
        .{exe_name},
    );
    std.process.exit(2);
}
