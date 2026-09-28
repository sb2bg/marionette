//! Small host-side baseline. Each runner call includes exact second execution.
const std = @import("std");
const builtin = @import("builtin");
const mar = @import("marionette");
const examples = @import("examples");

const samples = 10_000;
const first_seed = 0xC0FFEE;
const Totals = struct {
    trace_bytes: usize = 0,
    tape_bytes: usize = 0,
    decisions: usize = 0,
    events: u64 = 0,

    fn add(self: *Totals, report: *const mar.RunReport) void {
        const trace, const events, const tape = switch (report.*) {
            .passed => |v| .{ v.trace, v.event_count, v.decision_tape },
            .failed => |v| .{ v.first_trace, v.first_event_count, v.decision_tape },
        };
        self.trace_bytes += trace.len;
        self.events += events;
        self.decisions += tape.entries.len;
        self.tape_bytes += tape.entries.len * @sizeOf(mar.Decision);
        for (tape.entries) |entry| self.tape_bytes += entry.site_id.len + entry.byte_value.len;
    }
};

fn kv(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    var report = try examples.kv_store.runReport(allocator, seed, "baseline.kv", examples.kv_store.probabilisticScenario, &examples.kv_store.window_checks);
    errdefer report.deinit();
    if (report != .passed) return error.UnexpectedBaselineFailure;
    return report;
}

pub fn main(init: std.process.Init) !void {
    // Warm both code paths; compilation, warmup, and output are not timed.
    var warm_run = try kv(init.gpa, first_seed);
    warm_run.deinit();
    var warm_reduction = try examples.reduction.run(init.gpa, first_seed);
    warm_reduction.deinit();

    var runs: Totals = .{};
    const run_start = std.Io.Clock.awake.now(init.io).nanoseconds;
    for (0..samples) |index| {
        var report = try kv(init.gpa, first_seed + index);
        runs.add(&report);
        report.deinit();
    }
    const run_ns = std.Io.Clock.awake.now(init.io).nanoseconds - run_start;

    var originals: Totals = .{};
    var minimized: Totals = .{};
    var attempts: usize = 0;
    const reduction_start = std.Io.Clock.awake.now(init.io).nanoseconds;
    for (0..samples) |index| {
        var result = try examples.reduction.run(init.gpa, first_seed + index);
        defer result.deinit();
        if (!result.one_minimal or result.remaining_groups != 2) return error.UnexpectedReduction;
        originals.add(&result.original);
        minimized.add(result.report());
        attempts += result.attempts;
    }
    const reduction_ns = std.Io.Clock.awake.now(init.io).nanoseconds - reduction_start;
    const bytes = try std.json.Stringify.valueAlloc(init.gpa, .{
        .zig = builtin.zig_version_string,
        .target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag),
        .optimize = @tagName(builtin.mode),
        .samples = samples,
        .first_seed = first_seed,
        .kv = .{ .elapsed_ns = run_ns, .totals = runs },
        .reduction = .{ .elapsed_ns = reduction_ns, .max_attempts = (mar.ReductionOptions{}).max_attempts, .attempts = attempts, .original = originals, .minimized = minimized },
    }, .{});
    defer init.gpa.free(bytes);
    try std.Io.File.stdout().writeStreamingAll(init.io, bytes);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
