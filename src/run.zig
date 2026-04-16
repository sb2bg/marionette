//! Scenario runner with built-in deterministic replay verification.

const std = @import("std");

const clock_module = @import("clock.zig");
const World = @import("world.zig").World;

/// Configuration for one deterministic scenario run.
pub const RunOptions = struct {
    /// Seed for the world's random stream.
    seed: u64,
    /// Initial simulated timestamp in nanoseconds.
    start_ns: clock_module.Timestamp = 0,
    /// Nanoseconds advanced by one world tick.
    tick_ns: clock_module.Duration = clock_module.default_tick_ns,

    fn worldOptions(self: RunOptions) World.Options {
        return .{
            .seed = self.seed,
            .start_ns = self.start_ns,
            .tick_ns = self.tick_ns,
        };
    }
};

/// Successful scenario result.
pub const RunResult = struct {
    allocator: std.mem.Allocator,
    options: RunOptions,
    trace: []u8,
    event_count: u64,

    /// Release the owned trace.
    pub fn deinit(self: *RunResult) void {
        self.allocator.free(self.trace);
        self.* = undefined;
    }

    /// Transfer ownership of the trace to the caller.
    pub fn takeTrace(self: *RunResult) []u8 {
        const trace = self.trace;
        self.trace = &.{};
        self.event_count = 0;
        return trace;
    }
};

/// Failure kind captured by the runner.
pub const RunFailureKind = enum {
    /// The scenario returned an error. The first trace is the partial trace.
    scenario_error,
    /// Two executions with the same seed produced different traces.
    determinism_mismatch,
};

/// Data-bearing failure report.
pub const RunFailure = struct {
    allocator: std.mem.Allocator,
    options: RunOptions,
    kind: RunFailureKind,
    first_trace: []u8,
    second_trace: []u8 = &.{},
    first_event_count: u64,
    second_event_count: u64 = 0,
    scenario_error_name: ?[]const u8 = null,

    /// Release owned traces.
    pub fn deinit(self: *RunFailure) void {
        self.allocator.free(self.first_trace);
        self.allocator.free(self.second_trace);
        self.* = undefined;
    }

    /// Print a compact failure report.
    pub fn print(self: RunFailure) void {
        std.debug.print(
            "marionette failure: kind={s} seed={} start_ns={} tick_ns={} first_events={} second_events={}",
            .{
                @tagName(self.kind),
                self.options.seed,
                self.options.start_ns,
                self.options.tick_ns,
                self.first_event_count,
                self.second_event_count,
            },
        );
        if (self.scenario_error_name) |name| {
            std.debug.print(" scenario_error={s}", .{name});
        }
        std.debug.print("\n", .{});
    }
};

/// Result of `run`: either a verified replay or a data-bearing failure.
pub const RunReport = union(enum) {
    passed: RunResult,
    failed: RunFailure,

    /// Release any owned traces.
    pub fn deinit(self: *RunReport) void {
        switch (self.*) {
            .passed => |*passed| passed.deinit(),
            .failed => |*failed| failed.deinit(),
        }
        self.* = undefined;
    }
};

const RunOnceResult = union(enum) {
    passed: RunResult,
    failed: RunFailure,

    fn deinit(self: *RunOnceResult) void {
        switch (self.*) {
            .passed => |*passed| passed.deinit(),
            .failed => |*failed| failed.deinit(),
        }
        self.* = undefined;
    }
};

/// Run `scenario` twice with the same seed and compare byte-identical traces.
///
/// Scenario errors are returned as `RunReport.failed` with the partial trace
/// preserved. Allocation failures while setting up or copying runner-owned
/// traces are returned as normal Zig errors.
pub fn run(
    allocator: std.mem.Allocator,
    options: RunOptions,
    comptime scenario: fn (*World) anyerror!void,
) std.mem.Allocator.Error!RunReport {
    var first = try runOnce(allocator, options, scenario);
    switch (first) {
        .failed => |failure| return .{ .failed = failure },
        .passed => {},
    }
    errdefer first.deinit();

    var second = try runOnce(allocator, options, scenario);
    switch (second) {
        .failed => |failure| {
            const passed = first.passed;
            return .{ .failed = .{
                .allocator = allocator,
                .options = options,
                .kind = .scenario_error,
                .first_trace = passed.trace,
                .second_trace = failure.first_trace,
                .first_event_count = passed.event_count,
                .second_event_count = failure.first_event_count,
                .scenario_error_name = failure.scenario_error_name,
            } };
        },
        .passed => {},
    }
    errdefer second.deinit();

    const first_passed = first.passed;
    const second_passed = second.passed;
    if (!std.mem.eql(u8, first_passed.trace, second_passed.trace)) {
        return .{ .failed = .{
            .allocator = allocator,
            .options = options,
            .kind = .determinism_mismatch,
            .first_trace = first_passed.trace,
            .second_trace = second_passed.trace,
            .first_event_count = first_passed.event_count,
            .second_event_count = second_passed.event_count,
        } };
    }

    allocator.free(second_passed.trace);
    return .{ .passed = first_passed };
}

fn runOnce(
    allocator: std.mem.Allocator,
    options: RunOptions,
    comptime scenario: fn (*World) anyerror!void,
) std.mem.Allocator.Error!RunOnceResult {
    var world = try World.init(allocator, options.worldOptions());
    defer world.deinit();

    scenario(&world) catch |err| {
        return .{ .failed = .{
            .allocator = allocator,
            .options = options,
            .kind = .scenario_error,
            .first_trace = try allocator.dupe(u8, world.traceBytes()),
            .first_event_count = world.nextEventIndex(),
            .scenario_error_name = @errorName(err),
        } };
    };

    return .{ .passed = .{
        .allocator = allocator,
        .options = options,
        .trace = try allocator.dupe(u8, world.traceBytes()),
        .event_count = world.nextEventIndex(),
    } };
}

fn deterministicScenario(world: *World) !void {
    try world.tick();
    _ = try world.randomIntLessThan(u64, 100);
    try world.record("scenario.done", .{});
}

test "run: deterministic scenario passes with one owned trace" {
    var report = try run(std.testing.allocator, .{ .seed = 1234 }, deterministicScenario);
    defer report.deinit();

    switch (report) {
        .passed => |passed| {
            try std.testing.expectEqual(@as(u64, 4), passed.event_count);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "scenario.done") != null);
        },
        .failed => return error.UnexpectedRunFailure,
    }
}

var leak_counter: u64 = 0;

fn nondeterministicScenario(world: *World) !void {
    leak_counter += 1;
    try world.record("scenario.leak value={}", .{leak_counter});
}

test "run: same-seed trace mismatch is reported" {
    leak_counter = 0;
    var report = try run(std.testing.allocator, .{ .seed = 1234 }, nondeterministicScenario);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.determinism_mismatch, failure.kind);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "value=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.second_trace, "value=2") != null);
        },
    }
}

const ScenarioError = error{Boom};

fn failingScenario(world: *World) !void {
    try world.record("scenario.before_error", .{});
    return ScenarioError.Boom;
}

test "run: scenario errors preserve partial trace" {
    var report = try run(std.testing.allocator, .{ .seed = 1234 }, failingScenario);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.scenario_error, failure.kind);
            try std.testing.expectEqualStrings("Boom", failure.scenario_error_name.?);
            try std.testing.expectEqual(@as(u64, 2), failure.first_event_count);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scenario.before_error") != null);
        },
    }
}
