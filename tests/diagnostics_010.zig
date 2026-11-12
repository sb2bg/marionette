//! 0.10 diagnostics: choice sites in text traces, fault effects correlated
//! with their cause, strict capability mode, failure diagnosis, focused
//! histories, and summaries without empty wakes.
const std = @import("std");
const mar = @import("marionette");

const WriteFault = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }

    fn scenario(case: *mar.SimCase(@This())) !void {
        const io = case.env().io();
        var file = try std.Io.Dir.cwd().createFile(io, "data", .{});
        defer file.close(io);
        try case.control().disk.setFaults(.{ .write_error_rate = .always() });
        // The application handles the error; the evidence still links it.
        file.writePositionalAll(io, "DATA", 0) catch {};
    }

    fn failing(case: *mar.SimCase(@This())) !void {
        try scenario(case);
        return error.PlantedFailure;
    }
};

fn eventIndex(line: []const u8) u64 {
    const space = std.mem.indexOfScalar(u8, line, ' ').?;
    return std.fmt.parseInt(u64, line["event=".len..space], 10) catch unreachable;
}

test "diagnostics: a fault effect names its node, cause, error, fault event, and decision" {
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4 } },
        .init = WriteFault.init,
        .scenario = WriteFault.scenario,
    });
    defer report.deinit();
    const trace = report.passed.trace;

    // The decision event names its choice site.
    try mar.expectTraceContains(trace, "world.random_int_less_than site=disk.fault.write_error type=u32");
    const effect_at = std.mem.indexOf(u8, trace, "io.fault_effect node=0 incarnation=0 operation=write cause=WriteError error=InputOutput fault_event=").?;
    const effect_line = trace[std.mem.lastIndexOfScalar(u8, trace[0..effect_at], '\n').? + 1 ..][0 .. std.mem.indexOfScalar(u8, trace[effect_at..], '\n').? + effect_at - std.mem.lastIndexOfScalar(u8, trace[0..effect_at], '\n').? - 1];
    const fault_text = effect_line[std.mem.indexOf(u8, effect_line, "fault_event=").? + "fault_event=".len ..];
    const fault_event = try std.fmt.parseInt(u64, fault_text[0..std.mem.indexOfScalar(u8, fault_text, ' ').?], 10);

    // The named event is the fired fault roll.
    var lines = std.mem.splitScalar(u8, trace, '\n');
    var found = false;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "event=")) continue;
        if (eventIndex(line) != fault_event) continue;
        try std.testing.expect(std.mem.indexOf(u8, line, "disk.fault ") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "kind=write_error") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "fired=true") != null);
        found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(std.mem.indexOf(u8, effect_line, "decision=none") == null);
}

test "diagnostics: a failure explains itself with fault effects and a bounded tail" {
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4 } },
        .init = WriteFault.init,
        .scenario = WriteFault.failing,
    });
    defer report.deinit();
    var buffer: [16 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try report.failed.writeDiagnosis(&writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "fault effects: 1 observed by the application") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    caused by event=") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "trace tail: last 15 of 15 events (2 empty wakes omitted)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "scheduler.wake_empty") == null);

    // Focused histories select by path and node.
    writer = .fixed(&buffer);
    const path_events = try mar.writeTraceHistory(&writer, report.failed.first_trace, try mar.TraceFocus.parse("path:data"));
    try std.testing.expect(path_events >= 3);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "disk.write ") != null);
}

const Unmodeled = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }

    fn scenario(case: *mar.SimCase(@This())) !void {
        // Code that probes for symbolic links and falls back.
        std.Io.Dir.cwd().symLink(case.env().io(), "target", "link", .{}) catch {};
    }
};

test "diagnostics: strict capabilities mark a run unsupported even when the error is handled" {
    var permissive = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = Unmodeled.init,
        .scenario = Unmodeled.scenario,
    });
    defer permissive.deinit();
    try mar.expectTraceContains(permissive.passed.trace, "io.unmodeled operation=sym_link node=0 incarnation=0 strict=false");

    var strict = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{ .strict_capabilities = true },
        .init = Unmodeled.init,
        .scenario = Unmodeled.scenario,
    });
    defer strict.deinit();
    try std.testing.expectEqual(mar.RunFailureKind.unsupported_operation, strict.failed.kind);
    try std.testing.expectEqualStrings("sym_link", strict.failed.error_name.?);
}

test "diagnostics: summaries count empty wakes without listing them" {
    const trace =
        \\marionette.trace format=text version=5
        \\event=0 world.init seed=1 start_ns=0 tick_ns=1
        \\event=1 scheduler.wake_empty key=4 max=9
        \\event=2 app.step n=1
        \\
    ;
    var summary = try mar.summarize(std.testing.allocator, trace);
    defer summary.deinit();
    try std.testing.expectEqual(@as(u64, 3), summary.total_events);
    try std.testing.expectEqual(@as(u64, 1), summary.empty_wakes);
    for (summary.event_counts.items) |counter| {
        try std.testing.expect(!std.mem.eql(u8, counter.name, "scheduler.wake_empty"));
    }
}
