//! Crash-point sweeps: run one scenario once per disk operation, crashing
//! before that operation, until the armed operation completes.
//!
//! The scenario chooses where counting starts by calling
//! `SimCase.armCrashPoint` just before the work under test. Each point runs
//! through the ordinary runner, so it is recorded, exact-replayed, and
//! reproducible from its capsule: the point is a run attribute.
const std = @import("std");
const run = @import("run.zig");
const types = @import("run_types.zig");

pub const Options = struct {
    /// Upper bound on points, so an operation that never completes cannot
    /// sweep forever.
    max_points: u64 = 1024,
};

pub const Error = run.RunError || error{
    /// The scenario never called `SimCase.armCrashPoint`.
    CrashPointNotArmed,
    /// The armed crash still fired at `max_points`.
    CrashPointLimitReached,
};

/// Outcome of a sweep. Owns the first failing report, if any.
pub const Result = struct {
    /// Points run, including the final one where the armed crash never fired.
    points: u64 = 0,
    /// First failing point's report. Its options carry the point, so its
    /// capsule replays that point.
    failure: ?types.RunReport = null,

    pub fn deinit(self: *Result) void {
        if (self.failure) |*report| report.deinit();
        self.* = undefined;
    }
};

/// Sweep crash points 0, 1, 2, ... for an ordinary `runSimCase` config,
/// stopping at the first failure or at the first point where the armed crash
/// never fired because the work under test finished first.
pub fn sweepCrashPoints(config: anytype, options: Options) Error!Result {
    comptime run.requireKnownConfigFields(@TypeOf(config), "sweepCrashPoints", &.{});
    var result: Result = .{};
    while (result.points < options.max_points) {
        const point = result.points;
        var report = try run.runCrashPoint(config, point);
        result.points += 1;
        if (report == .failed) {
            result.failure = report;
            return result;
        }
        defer report.deinit();
        const trace = report.passed.trace;
        if (std.mem.indexOf(u8, trace, "disk.fault kind=armed_crash after_ops=") == null) return error.CrashPointNotArmed;
        if (std.mem.indexOf(u8, trace, "disk.fault kind=armed_crash fired=true") == null) return result;
    }
    return error.CrashPointLimitReached;
}

/// Expect every crash point to pass. Prints the first failure otherwise.
pub fn expectCrashPointsPass(config: anytype, options: Options) (Error || error{ExpectedRunPass})!void {
    var result = try sweepCrashPoints(config, options);
    defer result.deinit();
    if (result.failure) |failure| {
        failure.failed.print();
        return error.ExpectedRunPass;
    }
}
