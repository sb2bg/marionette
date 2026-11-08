//! Crash-point sweeps: run one scenario once per disk operation, crashing
//! before that operation, until the armed operation completes.
//!
//! The scenario chooses where counting starts by calling
//! `SimCase.armCrashPoint` just before the work under test. Each point runs
//! through the ordinary runner, so it is recorded, exact-replayed, and
//! reproducible from its capsule: the point and the named crash profile
//! are run attributes.
const artifact = @import("artifact.zig");
const run = @import("run.zig");
const types = @import("run_types.zig");
const trace_summary = @import("trace_summary.zig");
const CrashProfile = @import("disk/model.zig").CrashProfile;

/// Crash effects a sweep must produce somewhere among its points, so a
/// passing sweep cannot silently be a series of clean restarts.
pub const EffectRequirement = enum {
    none,
    /// At least one pending data operation lost, torn, or reordered.
    data,
    /// At least one pending namespace change rolled back.
    metadata,
    /// Both of the above, possibly at different points.
    data_and_metadata,

    pub fn metBy(self: EffectRequirement, effects: trace_summary.CrashEffects) bool {
        return switch (self) {
            .none => true,
            .data => effects.data_effects != 0,
            .metadata => effects.metadata_effects != 0,
            .data_and_metadata => effects.data_effects != 0 and effects.metadata_effects != 0,
        };
    }
};

pub const Options = struct {
    /// Crash-time semantics applied when each point is armed. Required:
    /// a sweep states what a crash may do. Use `.clean` for a deliberate
    /// clean crash.
    profile: CrashProfile,
    /// Effects the sweep must observe; checked when no point fails.
    require: EffectRequirement = .none,
    /// Upper bound on points, so an operation that never completes cannot
    /// sweep forever.
    max_points: u64 = 1024,
};

pub const Error = run.RunError || error{
    /// The scenario never called `SimCase.armCrashPoint`.
    CrashPointNotArmed,
    /// The armed crash still fired at `max_points`.
    CrashPointLimitReached,
    /// Every point passed, but no point produced an effect the sweep
    /// required: the profile or workload left nothing for a crash to act on.
    CrashEffectRequirementUnmet,
    /// `config.artifacts.include_passes` asks for every passing point, but a
    /// sweep writes only its failing point to the one named directory.
    InvalidCrashSweepArtifacts,
};

/// Outcome of a sweep. Owns the first failing report, if any.
pub const Result = struct {
    /// Points run, including the final one where the armed crash never fired.
    points: u64 = 0,
    /// Points where the armed crash fired.
    injected: u64 = 0,
    /// Injected points with pending state the profile could act on.
    eligible: u64 = 0,
    /// Injected points whose crash changed pending data or namespace state.
    effective: u64 = 0,
    /// Crash effects summed over every point run.
    effects: trace_summary.CrashEffects = .{},
    /// First failing point's report. Its options carry the point, so its
    /// capsule replays that point.
    failure: ?types.RunReport = null,

    pub fn deinit(self: *Result) void {
        if (self.failure) |*report| report.deinit();
        self.* = undefined;
    }

    /// Classify one point from its trace. The runner's own trace is
    /// well-formed, so a parse failure means no crash evidence to count.
    fn record(self: *Result, trace: []const u8) void {
        const effects = trace_summary.crashEffects(trace) catch return;
        self.effects.add(effects);
        if (effects.injected != 0) self.injected += 1;
        if (effects.eligible != 0) self.eligible += 1;
        if (effects.data_effects != 0 or effects.metadata_effects != 0) self.effective += 1;
    }
};

/// Sweep crash points 0, 1, 2, ... for an ordinary `runSimCase` config,
/// stopping at the first failure or at the first point where the armed crash
/// never fired because the work under test finished first. With
/// `config.artifacts`, the first failing point is written there.
pub fn sweepCrashPoints(config: anytype, options: Options) Error!Result {
    comptime run.requireKnownConfigFields(@TypeOf(config), "sweepCrashPoints", &.{});
    if (@hasField(@TypeOf(config), "artifacts")) {
        if (config.artifacts.include_passes) return error.InvalidCrashSweepArtifacts;
    }
    var result: Result = .{};
    while (result.points < options.max_points) {
        const point = result.points;
        var report = try run.runCrashPoint(config, point, options.profile);
        result.points += 1;
        if (report == .failed) {
            errdefer report.deinit();
            result.record(report.failed.first_trace);
            if (@hasField(@TypeOf(config), "artifacts")) try artifact.write(config.allocator, &report, config.artifacts);
            result.failure = report;
            return result;
        }
        defer report.deinit();
        const fired = report.passed.crash_point_fired orelse return error.CrashPointNotArmed;
        result.record(report.passed.trace);
        if (!fired) {
            if (!options.require.metBy(result.effects)) return error.CrashEffectRequirementUnmet;
            return result;
        }
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
