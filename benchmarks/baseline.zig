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

const net_samples = 1_000;
const net_transfer_bytes = 64 * 1024;

const NetApp = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }

    fn scenario(case: *mar.SimCase(@This())) !void {
        const server_io = (try case.sim.envForNode(0)).io();
        const client_io = (try case.sim.envForNode(1)).io();
        try case.control().network.setLatency(.{ .min_latency_ns = 1_000_000, .latency_jitter_ns = 1_000_000 });
        try case.control().network.setLossiness(.{ .drop_rate = .percent(1) });
        const address = mar.AnyNetworkControl.hostIp4(0, 9000);
        var listener = try address.listen(server_io, .{});
        defer listener.deinit(server_io);
        const client = try address.connect(client_io, .{ .mode = .stream });
        defer client.close(client_io);
        const server = try listener.accept(server_io);
        defer server.close(server_io);

        var payload: [net_transfer_bytes]u8 = undefined;
        for (&payload, 0..) |*byte, index| byte.* = @truncate(index);
        var writer = client.writer(client_io, &.{});
        var sender = try std.Io.concurrent(client_io, sendAll, .{ &writer, &payload });
        defer sender.cancel(client_io) catch {};
        var received: [net_transfer_bytes]u8 = undefined;
        var reader = server.reader(server_io, &.{});
        try reader.interface.readSliceAll(&received);
        try sender.await(client_io);
        if (!std.mem.eql(u8, &payload, &received)) return error.CorruptTransfer;
    }

    fn sendAll(writer: *std.Io.net.Stream.Writer, bytes: []const u8) !void {
        try writer.interface.writeAll(bytes);
    }
};

fn net(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    var report = try mar.runSimCase(.{
        .allocator = allocator,
        .seed = seed,
        .tick_ns = 1_000_000,
        .name = "baseline.net",
        .simulate = mar.World.SimulateOptions{ .network = .{ .nodes = 2 } },
        .init = NetApp.init,
        .scenario = NetApp.scenario,
    });
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

    var warm_net = try net(init.gpa, first_seed);
    warm_net.deinit();
    var net_runs: Totals = .{};
    const net_start = std.Io.Clock.awake.now(init.io).nanoseconds;
    for (0..net_samples) |index| {
        var report = try net(init.gpa, first_seed + index);
        net_runs.add(&report);
        report.deinit();
    }
    const net_ns = std.Io.Clock.awake.now(init.io).nanoseconds - net_start;
    const bytes = try std.json.Stringify.valueAlloc(init.gpa, .{
        .zig = builtin.zig_version_string,
        .target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag),
        .optimize = @tagName(builtin.mode),
        .samples = samples,
        .first_seed = first_seed,
        .kv = .{ .elapsed_ns = run_ns, .totals = runs },
        .reduction = .{ .elapsed_ns = reduction_ns, .max_attempts = (mar.ReductionOptions{}).max_attempts, .attempts = attempts, .original = originals, .minimized = minimized },
        .net = .{ .samples = net_samples, .transfer_bytes = net_transfer_bytes, .elapsed_ns = net_ns, .totals = net_runs },
    }, .{});
    defer init.gpa.free(bytes);
    try std.Io.File.stdout().writeStreamingAll(init.io, bytes);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");

    // `--budget <path>` checks the deterministic totals against limits.
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (!std.mem.eql(u8, arg, "--budget")) return error.UnknownArgument;
        const path = args.next() orelse return error.MissingBudgetPath;
        const budget_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(64 * 1024));
        defer init.gpa.free(budget_bytes);
        const parsed = try std.json.parseFromSlice(Budget, init.gpa, budget_bytes, .{});
        defer parsed.deinit();
        var over = false;
        over = checkTotals(init, "kv", runs, parsed.value.kv) or over;
        over = checkTotals(init, "reduction.minimized", minimized, parsed.value.reduction_minimized) or over;
        over = checkTotals(init, "net", net_runs, parsed.value.net) or over;
        if (over) return error.BaselineBudgetExceeded;
        try std.Io.File.stdout().writeStreamingAll(init.io, "baseline budget ok\n");
    }
}

/// Deterministic per-workload limits. Elapsed time is reported but never
/// budgeted: it depends on the machine.
const Budget = struct {
    kv: Totals,
    reduction_minimized: Totals,
    net: Totals,
};

fn checkTotals(init: std.process.Init, name: []const u8, actual: Totals, limit: Totals) bool {
    var over = false;
    inline for (.{ "trace_bytes", "tape_bytes", "decisions", "events" }) |field| {
        if (@field(actual, field) > @field(limit, field)) {
            over = true;
            var buffer: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&buffer, "baseline budget exceeded: {s}.{s} actual={} limit={}\n", .{
                name, field, @field(actual, field), @field(limit, field),
            }) catch "baseline budget exceeded\n";
            std.Io.File.stderr().writeStreamingAll(init.io, line) catch {};
        }
    }
    return over;
}
