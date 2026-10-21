//! Campaign-to-regression validation on pinned external systems.
//!
//! Each command runs in its own process, so evidence crosses a real process
//! boundary:
//!
//!   run     start a fresh campaign; `--kill-after-cases K` exits the process
//!           abruptly near case K, leaving only the last journal checkpoint
//!   resume  finish the remaining cases from that checkpoint
//!   verify  load the journal, replay every retained capsule, reduce it again
//!           from the capsule alone, and check the workload's expected outcome
//!
//! Workloads with a `-mutant` suffix use a deliberately over-strong oracle so
//! the failure path is exercised on real code; the others must find nothing.
const std = @import("std");
const mar = @import("marionette");
const redis = @import("redis_workload.zig");
const xitdb = @import("xitdb_workload.zig");

const kill_exit_code = 75;

// The Redis client logs every attempt at debug level.
pub const std_options: std.Options = .{ .log_level = .warn };

fn Spec(comptime Module: type, comptime checks: []const mar.StateCheck(mar.SimCase(Module.App))) type {
    return struct {
        const App = Module.App;
        const Case = mar.SimCase(App);

        fn config(allocator: std.mem.Allocator, seed: u64) Config {
            return .{ .allocator = allocator, .seed = seed };
        }

        const Config = struct {
            allocator: std.mem.Allocator,
            seed: u64,
            tick_ns: u64 = Module.tick_ns,
            simulate: mar.World.SimulateOptions = Module.simulateOptions(),
            comptime init: @TypeOf(initCounted) = initCounted,
            comptime scenario: @TypeOf(Module.scenario) = Module.scenario,
            comptime checks: []const mar.StateCheck(Case) = checks,
        };

        /// Count executions so `run` can kill its own process mid-campaign.
        fn initCounted(sim: mar.Sim) !App {
            executions += 1;
            if (kill_at_execution) |limit| if (executions >= limit) std.process.exit(kill_exit_code);
            return App.init(sim);
        }
    };
}

const Entry = struct {
    name: []const u8,
    sut: []const u8,
    seed: u64,
    expect_failures: bool,
    Spec: type,
};

const entries = [_]Entry{
    .{ .name = "xitdb-acknowledged-history", .sut = "xitdb@f8a85b68f02dcc60e91c545c5d1fb972735e01e9", .seed = 0x7817_0001, .expect_failures = false, .Spec = Spec(xitdb, &xitdb.acknowledged_history_checks) },
    .{ .name = "xitdb-victim-durable-mutant", .sut = "xitdb@f8a85b68f02dcc60e91c545c5d1fb972735e01e9", .seed = 0x7817_0002, .expect_failures = true, .Spec = Spec(xitdb, &xitdb.victim_durable_checks) },
    .{ .name = "redis-at-least-once", .sut = "redis.zig@4879d5a6e6318fe8ec8b0f3df4e37239c0c3e78c", .seed = 0x4ED1_0001, .expect_failures = false, .Spec = Spec(redis, &redis.at_least_once_checks) },
    .{ .name = "redis-exactly-once-mutant", .sut = "redis.zig@4879d5a6e6318fe8ec8b0f3df4e37239c0c3e78c", .seed = 0x4ED1_0002, .expect_failures = true, .Spec = Spec(redis, &redis.exactly_once_checks) },
};

var executions: u64 = 0;
var kill_at_execution: ?u64 = null;

const Command = enum { run, @"resume", verify };

const Args = struct {
    root: []const u8,
    workload: []const u8,
    command: Command,
    cases: u64 = 64,
    kill_after_cases: ?u64 = null,
    reduction_attempts: usize = 256,
};

pub fn main(init: std.process.Init) !void {
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer iterator.deinit();
    _ = iterator.next();
    const args = parseArgs(&iterator) catch return usage(init.io);
    inline for (entries) |entry| {
        if (std.mem.eql(u8, args.workload, entry.name)) return execute(entry, init, args);
    }
    return usage(init.io);
}

fn parseArgs(iterator: *std.process.Args.Iterator) !Args {
    var args: Args = .{
        .root = iterator.next() orelse return error.Usage,
        .workload = iterator.next() orelse return error.Usage,
        .command = std.meta.stringToEnum(Command, iterator.next() orelse return error.Usage) orelse return error.Usage,
    };
    while (iterator.next()) |flag| {
        const value = iterator.next() orelse return error.Usage;
        const number = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, flag, "--cases")) {
            args.cases = number;
        } else if (std.mem.eql(u8, flag, "--kill-after-cases")) {
            args.kill_after_cases = number;
        } else if (std.mem.eql(u8, flag, "--reduction-attempts")) {
            args.reduction_attempts = @intCast(number);
        } else return error.Usage;
    }
    return args;
}

fn execute(comptime entry: Entry, init: std.process.Init, args: Args) !void {
    const io = init.io;
    const identity: mar.ReplayIdentity = .{ .build = "marionette-campaign-validation", .sut = entry.sut };
    var root = try std.Io.Dir.cwd().createDirPathOpen(io, args.root, .{});
    defer root.close(io);
    const config = entry.Spec.config(init.gpa, entry.seed);

    switch (args.command) {
        .run, .@"resume" => {
            const fresh = args.command == .run;
            if (fresh) {
                root.deleteTree(io, entry.name) catch {};
                // Each case records and replays: two executions per case.
                if (args.kill_after_cases) |cases| kill_at_execution = 2 * cases + 1;
            }
            var summary = try mar.runCampaign(config, .{
                .io = io,
                .cases = args.cases,
                .reduction = .{ .max_attempts = args.reduction_attempts },
                .artifacts = .{
                    .parent = root,
                    .name = entry.name,
                    .identity = identity,
                    .resume_existing = !fresh,
                    // Checkpoint at every case boundary so a kill loses one case.
                    .checkpoint_interval_ns = 0,
                },
            });
            defer summary.deinit();
            try printMetrics(init, entry.name, @tagName(args.command), &summary);
        },
        .verify => {
            var dir = try root.openDir(io, entry.name, .{});
            defer dir.close(io);
            var summary = try mar.loadCampaignSummary(init.gpa, io, dir);
            defer summary.deinit();
            try verify(entry, init, dir, &summary, identity, args.reduction_attempts);
            try printMetrics(init, entry.name, "verify", &summary);
        },
    }
}

/// Everything here comes from the campaign directory and the pinned harness.
fn verify(comptime entry: Entry, init: std.process.Init, dir: std.Io.Dir, summary: *const mar.CampaignSummary, identity: mar.ReplayIdentity, max_attempts: usize) !void {
    const io = init.io;
    const allocator = init.gpa;
    if (summary.stop_reason != .completed or summary.executed_cases != summary.planned_cases) return error.CampaignIncomplete;
    if (summary.errors.len != 0) return error.CampaignRunnerErrors;
    if (entry.expect_failures and summary.failures.len == 0) return error.ExpectedFailureNotFound;
    if (!entry.expect_failures and summary.failures.len != 0) return error.UnexpectedFailure;

    for (summary.failures) |failure| {
        if (!failure.reproducible) return error.FailureNotReproducible;
        var failure_dir = try dir.openDir(io, failure.artifact_name.?, .{});
        defer failure_dir.close(io);
        const bytes = try failure_dir.readFileAlloc(io, "replay.json", allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(bytes);
        var capsule = try mar.ReplayCapsule.decode(allocator, bytes);
        defer capsule.deinit();
        const config = entry.Spec.config(allocator, capsule.options().seed);

        var replayed = try mar.replaySimCase(config, &capsule, identity);
        defer replayed.deinit();
        if (replayed != .failed or !failure.fingerprint.eql(mar.FailureFingerprint.from(replayed.failed))) return error.CapsuleDidNotReproduce;

        const reduction = failure.reduction orelse return error.FailureNotReduced;
        // The same budget from a fresh process must retrace the same reduction.
        var reduced = try mar.reduceCapsule(config, &capsule, identity, .{ .max_attempts = max_attempts });
        defer reduced.deinit();
        if (reduced.attempts != reduction.attempts or reduced.remaining_groups != reduction.remaining_groups) return error.ReductionDiverged;
        if (reduction.minimized) {
            const retained = try failure_dir.readFileAlloc(io, "reduced/trace.txt", allocator, .limited(64 * 1024 * 1024));
            defer allocator.free(retained);
            if (!std.mem.eql(u8, retained, reduced.report().failed.first_trace)) return error.ReductionDiverged;
        }
    }
}

fn printMetrics(init: std.process.Init, name: []const u8, command: []const u8, summary: *const mar.CampaignSummary) !void {
    const bytes = try std.json.Stringify.valueAlloc(init.gpa, .{
        .workload = name,
        .command = command,
        .executed_cases = summary.executed_cases,
        .planned_cases = summary.planned_cases,
        .start_case = summary.start_case,
        .failed_cases = summary.failed_cases,
        .elapsed_ns = summary.elapsed_ns,
        .metrics = summary.metrics(),
    }, .{});
    defer init.gpa.free(bytes);
    try std.Io.File.stdout().writeStreamingAll(init.io, bytes);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(io,
        \\usage: marionette-campaigns <root> <workload> <run|resume|verify>
        \\         [--cases N] [--kill-after-cases K] [--reduction-attempts N]
        \\workloads: xitdb-acknowledged-history xitdb-victim-durable-mutant
        \\           redis-at-least-once redis-exactly-once-mutant
        \\
    );
    return error.Usage;
}
