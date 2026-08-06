//! CLI entry point for running Marionette examples by seed.

const std = @import("std");
const examples = @import("examples");
const mar = @import("marionette");
const std_io_net_kv_validation = @import("std_io_net_kv_validation");

const default_seed: u64 = 0xC0FFEE;

const Mode = enum {
    summary,
    trace,
};

const TraceRunner = *const fn (std.mem.Allocator, u64) anyerror![]u8;
const ReportRunner = *const fn (std.mem.Allocator, u64) anyerror!mar.RunReport;

const Scenario = struct {
    name: []const u8,
    runner: union(enum) {
        trace: TraceRunner,
        report: ReportRunner,
        std_io_net: std_io_net_kv_validation.ScenarioMode,
    },
};

const scenarios = [_]Scenario{
    .{ .name = "retry-queue", .runner = .{ .trace = examples.retry_queue.runScenario } },
    .{ .name = "retry-queue-bug", .runner = .{ .report = examples.retry_queue.runBuggyScenarioReport } },
    .{ .name = "replicated-register", .runner = .{ .trace = examples.replicated_register.runScenario } },
    .{ .name = "replicated-register-bug", .runner = .{ .report = examples.replicated_register.runBuggyScenarioReport } },
    .{ .name = "replicated-register-partition", .runner = .{ .trace = examples.replicated_register.runPartitionScenario } },
    .{ .name = "replicated-register-conflict", .runner = .{ .trace = examples.replicated_register.runConflictScenario } },
    .{ .name = "durable-broadcast", .runner = .{ .trace = examples.durable_broadcast.runScenario } },
    .{ .name = "durable-broadcast-bug", .runner = .{ .report = examples.durable_broadcast.runBuggyScenarioReport } },
    .{ .name = "kv-store", .runner = .{ .report = runKvStore } },
    .{ .name = "kv-store-bug", .runner = .{ .report = runKvStoreBug } },
    .{ .name = "idempotency-bug", .runner = .{ .report = examples.idempotency_bug.runReport } },
    .{ .name = "std-io-net-kv", .runner = .{ .std_io_net = .retry_safe } },
    .{ .name = "std-io-net-kv-bug", .runner = .{ .std_io_net = .retry_buggy } },
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
    for (scenarios) |entry| {
        if (!std.mem.eql(u8, scenario, entry.name)) continue;

        switch (entry.runner) {
            .trace => |run_trace| {
                const trace = try run_trace(allocator, seed);
                defer allocator.free(trace);
                if (expect_failure) return expectedFailureDidNotHappen();
                try printTraceOrSummary(allocator, trace, mode);
            },
            .report => |run_report| try printReport(
                allocator,
                try run_report(allocator, seed),
                mode,
                expect_failure,
            ),
            .std_io_net => |scenario_mode| try runStdIoNetKv(
                allocator,
                seed,
                mode,
                expect_failure,
                scenario_mode,
            ),
        }
        return;
    }

    std.debug.print("unknown scenario: {s}\n", .{scenario});
    std.process.exit(2);
}

fn runStdIoNetKv(
    allocator: std.mem.Allocator,
    seed: u64,
    mode: Mode,
    expect_failure: bool,
    scenario_mode: std_io_net_kv_validation.ScenarioMode,
) !void {
    var outcome = try std_io_net_kv_validation.runScenario(
        allocator,
        seed,
        scenario_mode,
    );
    defer outcome.deinit();

    try printTraceOrSummary(allocator, outcome.trace, mode);
    if (outcome.invariant_violated) {
        if (!expect_failure) std.process.exit(1);
    } else if (expect_failure) {
        return expectedFailureDidNotHappen();
    }
}

fn runKvStore(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return examples.kv_store.runReport(
        allocator,
        seed,
        "kv-store",
        examples.kv_store.scenario,
        &examples.kv_store.checks,
    );
}

fn runKvStoreBug(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return examples.kv_store.runReport(
        allocator,
        seed,
        "kv-store-bug",
        examples.kv_store.buggyScenario,
        &examples.kv_store.checks,
    );
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

fn printReport(
    allocator: std.mem.Allocator,
    report: mar.RunReport,
    mode: Mode,
    expect_failure: bool,
) !void {
    var owned_report = report;
    defer owned_report.deinit();

    switch (owned_report) {
        .passed => |passed| {
            if (expect_failure) return expectedFailureDidNotHappen();
            try printTraceOrSummary(allocator, passed.trace, mode);
        },
        .failed => |failure| {
            if (mode == .trace) {
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

fn expectedFailureDidNotHappen() noreturn {
    std.debug.print("marionette passed unexpectedly with --expect-failure\n", .{});
    std.process.exit(1);
}

fn usage(exe_name: []const u8) noreturn {
    std.debug.print(
        \\usage: {s} <scenario> [--seed <seed>] [--summary|--trace] [--expect-failure]
        \\
        \\scenarios:
        \\
    ,
        .{exe_name},
    );
    for (scenarios) |scenario| std.debug.print("  {s}\n", .{scenario.name});
    std.process.exit(2);
}
