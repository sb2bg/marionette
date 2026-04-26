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
    } else if (std.mem.eql(u8, scenario, "kv-store")) {
        const trace = try runKvStoreTrace(allocator, seed, examples.kv_store.scenario);
        defer allocator.free(trace);
        if (expect_failure) return expectedFailureDidNotHappen();
        try printTraceOrSummary(allocator, trace, mode);
    } else if (std.mem.eql(u8, scenario, "kv-store-bug")) {
        try printReport(try runKvStoreReport(allocator, seed, examples.kv_store.buggyScenario), expect_failure);
    } else if (std.mem.eql(u8, scenario, "idempotency-bug")) {
        try printSeedSensitiveReport(allocator, try runIdempotencyBugReport(allocator, seed), mode, expect_failure);
    } else {
        std.debug.print("unknown scenario: {s}\n", .{scenario});
        std.process.exit(2);
    }
}

fn runKvStoreTrace(
    allocator: std.mem.Allocator,
    seed: u64,
    comptime scenario_fn: fn (*examples.kv_store.Harness) anyerror!void,
) ![]u8 {
    var report = try runKvStoreReport(allocator, seed, scenario_fn);
    defer report.deinit();

    switch (report) {
        .passed => |*passed| return passed.takeTrace(),
        .failed => |failure| {
            failure.print();
            return error.UnexpectedRunFailure;
        },
    }
}

fn runKvStoreReport(
    allocator: std.mem.Allocator,
    seed: u64,
    comptime scenario_fn: fn (*examples.kv_store.Harness) anyerror!void,
) !mar.RunReport {
    return mar.runCase(.{
        .allocator = allocator,
        .seed = seed,
        .tick_ns = examples.kv_store.tick_ns,
        .init = examples.kv_store.Harness.init,
        .scenario = scenario_fn,
        .checks = &examples.kv_store.checks,
    });
}

fn runIdempotencyBugReport(
    allocator: std.mem.Allocator,
    seed: u64,
) !mar.RunReport {
    return mar.runCase(.{
        .allocator = allocator,
        .seed = seed,
        .init = examples.idempotency_bug.Harness.init,
        .scenario = examples.idempotency_bug.scenario,
        .checks = &examples.idempotency_bug.checks,
    });
}

fn printSeedSensitiveReport(
    allocator: std.mem.Allocator,
    report: mar.RunReport,
    mode: Mode,
    expect_failure: bool,
) !void {
    var owned_report = report;
    defer owned_report.deinit();

    switch (owned_report) {
        .passed => |*passed| {
            if (expect_failure) return expectedFailureDidNotHappen();
            const trace = passed.takeTrace();
            defer allocator.free(trace);
            try printTraceOrSummary(allocator, trace, mode);
        },
        .failed => |failure| {
            if (expect_failure and mode == .trace) {
                std.debug.print("{s}", .{failure.first_trace});
            } else {
                var buffer: [4096]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&buffer);
                try failure.writeSummary(&writer);
                std.debug.print("{s}", .{writer.buffered()});
            }
            if (!expect_failure) std.process.exit(1);
        },
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
        \\  kv-store
        \\  kv-store-bug
        \\  idempotency-bug
        \\
    ,
        .{exe_name},
    );
    std.process.exit(2);
}
