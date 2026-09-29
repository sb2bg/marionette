//! Bounded unattended seed campaigns over an ordinary simulation config.
//!
//! A campaign runs many recorded cases, keeps going through failing, killed,
//! and crashed cases, groups failures by full failure identity, and retains
//! evidence for each distinct failure. Host time and files come only from the
//! caller's `std.Io`; nothing here enters simulated time or the choice stream.
const std = @import("std");
const artifact = @import("artifact.zig");
const reduce = @import("reduce.zig");
const replay = @import("replay.zig");
const run = @import("run.zig");
const types = @import("run_types.zig");

pub const Error = std.mem.Allocator.Error || artifact.Error || error{
    InvalidCampaignOptions,
    InvalidSeedSchedule,
    InvalidStateChecks,
    InvalidWatchdogOptions,
    WatchdogUnavailable,
};

pub const Options = struct {
    /// Host capability for the time budget and evidence files.
    io: std.Io,
    /// Cases to run. Case `i` uses the same seed as `expectSimFuzz`
    /// iteration `i` for the config's `seed`. Must be positive.
    cases: u64,
    /// Host monotonic budget, checked after each case, so at least one case
    /// runs. With a watchdog, one case adds at most two `run_timeout_ns`.
    time_budget_ns: ?u64 = null,
    /// Stop after this many failing cases.
    max_failures: ?u64 = null,
    /// Directory for per-failure artifacts and the campaign summary.
    artifacts: ?Artifacts = null,
};

pub const Artifacts = struct {
    parent: std.Io.Dir,
    /// New campaign directory: one relative component, never overwritten.
    name: []const u8,
    identity: replay.Identity,
};

pub const StopReason = enum { completed, time_budget, failure_limit };

/// First occurrence and count of one full failure identity.
pub const DistinctFailure = struct {
    fingerprint: reduce.FailureFingerprint,
    digest: u64,
    first_case: u64,
    first_seed: u64,
    occurrences: u64 = 1,
    /// Exactly reproduced with a complete tape, so its capsule replays and
    /// it is eligible for reduction.
    reproducible: bool,
    /// Directory under the campaign directory holding the first occurrence.
    artifact_name: ?[]const u8 = null,
};

/// A case whose runner infrastructure failed, such as a worker result that
/// exceeded its watchdog capacity. The campaign records it and continues.
pub const CaseError = struct {
    case: u64,
    seed: u64,
    error_name: []const u8,
};

pub const Summary = struct {
    allocator: std.mem.Allocator,
    base_seed: u64,
    planned_cases: u64,
    executed_cases: u64 = 0,
    passed_cases: u64 = 0,
    failed_cases: u64 = 0,
    stop_reason: StopReason = .completed,
    elapsed_ns: u64 = 0,
    failures: []DistinctFailure = &.{},
    errors: []CaseError = &.{},

    pub fn deinit(self: *Summary) void {
        for (self.failures) |failure| deinitFailure(self.allocator, failure);
        self.allocator.free(self.failures);
        self.allocator.free(self.errors);
        self.* = undefined;
    }
};

/// Run a bounded campaign. `config` is an ordinary `runSimCase` config; its
/// `seed` keys case seeds and its `watchdog` isolates each case so hangs and
/// crashes become failures instead of stopping the campaign. Use `artifacts`
/// on the campaign options rather than on the config.
pub fn runCampaign(config: anytype, options: Options) Error!Summary {
    if (comptime @hasField(@TypeOf(config), "artifacts")) {
        @compileError("runCampaign writes artifacts itself; set Options.artifacts instead of config.artifacts");
    }
    if (options.cases == 0) return error.InvalidCampaignOptions;
    if (options.max_failures) |limit| if (limit == 0) return error.InvalidCampaignOptions;
    if (@hasField(@TypeOf(config), "watchdog")) {
        if (@as(?types.WatchdogOptions, config.watchdog) != null and !@import("watchdog.zig").supported) return error.WatchdogUnavailable;
    }
    const allocator = config.allocator;

    var directory: ?std.Io.Dir = null;
    defer if (directory) |dir| dir.close(options.io);
    if (options.artifacts) |target| directory = try createCampaignDir(options.io, target);

    var failures: std.ArrayList(DistinctFailure) = .empty;
    defer {
        for (failures.items) |failure| deinitFailure(allocator, failure);
        failures.deinit(allocator);
    }
    var errors: std.ArrayList(CaseError) = .empty;
    defer errors.deinit(allocator);

    var summary: Summary = .{
        .allocator = allocator,
        .base_seed = run.configSeed(config),
        .planned_cases = options.cases,
    };
    const started = now(options.io);
    for (0..options.cases) |case| {
        try runCase(config, options, case, directory, &summary, &failures, &errors);
        if (case + 1 == options.cases) break;
        if (options.max_failures) |limit| if (summary.failed_cases >= limit) {
            summary.stop_reason = .failure_limit;
            break;
        };
        if (options.time_budget_ns) |budget| if (now(options.io) -| started >= budget) {
            summary.stop_reason = .time_budget;
            break;
        };
    }
    summary.elapsed_ns = now(options.io) -| started;
    summary.failures = try failures.toOwnedSlice(allocator);
    errdefer {
        for (summary.failures) |failure| deinitFailure(allocator, failure);
        allocator.free(summary.failures);
    }
    summary.errors = try errors.toOwnedSlice(allocator);
    errdefer allocator.free(summary.errors);
    if (directory) |dir| try writeSummary(allocator, options.io, dir, options.artifacts.?.identity, config, &summary);
    return summary;
}

fn runCase(
    config: anytype,
    options: Options,
    case: u64,
    directory: ?std.Io.Dir,
    summary: *Summary,
    failures: *std.ArrayList(DistinctFailure),
    errors: *std.ArrayList(CaseError),
) Error!void {
    const allocator = config.allocator;
    const seed = run.caseSeed(config, case);
    summary.executed_cases += 1;
    var report = run.runSeededCase(config, seed) catch |err| switch (err) {
        // Configuration errors would fail every case identically, and host
        // memory exhaustion is not a property of one case.
        error.InvalidSeedSchedule, error.InvalidStateChecks, error.InvalidWatchdogOptions, error.OutOfMemory => |fatal| return fatal,
        else => return errors.append(allocator, .{ .case = case, .seed = seed, .error_name = @errorName(err) }),
    };
    defer report.deinit();
    switch (report) {
        .passed => summary.passed_cases += 1,
        .failed => |failure| {
            summary.failed_cases += 1;
            try recordFailure(allocator, failures, &report, failure, case, seed, directory, options);
        },
    }
}

fn recordFailure(
    allocator: std.mem.Allocator,
    failures: *std.ArrayList(DistinctFailure),
    report: *const types.RunReport,
    failure: types.RunFailure,
    case: u64,
    seed: u64,
    directory: ?std.Io.Dir,
    options: Options,
) Error!void {
    const fingerprint = reduce.FailureFingerprint.from(failure);
    for (failures.items) |*known| {
        if (known.fingerprint.eql(fingerprint)) {
            known.occurrences += 1;
            return;
        }
    }
    var distinct: DistinctFailure = .{
        .fingerprint = try cloneFingerprint(allocator, fingerprint),
        .digest = fingerprint.digest(),
        .first_case = case,
        .first_seed = seed,
        .reproducible = reduce.reproducible(report.*),
    };
    errdefer deinitFailure(allocator, distinct);
    if (directory) |dir| {
        const name = try std.fmt.allocPrint(allocator, "failure-{x:0>16}", .{distinct.digest});
        distinct.artifact_name = name;
        try artifact.write(allocator, report, .{
            .io = options.io,
            .parent = dir,
            .name = name,
            .identity = options.artifacts.?.identity,
        });
    }
    try failures.append(allocator, distinct);
}

fn cloneFingerprint(allocator: std.mem.Allocator, fingerprint: reduce.FailureFingerprint) std.mem.Allocator.Error!reduce.FailureFingerprint {
    const error_name = if (fingerprint.error_name) |name| try allocator.dupe(u8, name) else null;
    errdefer if (error_name) |name| allocator.free(name);
    const check_name = if (fingerprint.check_name) |name| try allocator.dupe(u8, name) else null;
    return .{ .kind = fingerprint.kind, .error_name = error_name, .check_name = check_name };
}

fn deinitFailure(allocator: std.mem.Allocator, failure: DistinctFailure) void {
    if (failure.fingerprint.error_name) |name| allocator.free(name);
    if (failure.fingerprint.check_name) |name| allocator.free(name);
    if (failure.artifact_name) |name| allocator.free(name);
}

fn createCampaignDir(io: std.Io, target: Artifacts) Error!std.Io.Dir {
    if (target.identity.build.len == 0 or target.identity.sut.len == 0) return error.InvalidReplayIdentity;
    try artifact.validateName(target.name);
    target.parent.createDir(io, target.name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.ArtifactAlreadyExists,
        else => return error.ArtifactIoFailed,
    };
    return target.parent.openDir(io, target.name, .{}) catch error.ArtifactIoFailed;
}

// The summary is written last, like an artifact manifest: its presence marks
// a campaign that finished its bookkeeping.
fn writeSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    identity: replay.Identity,
    config: anytype,
    summary: *const Summary,
) Error!void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{
        .format = "marionette.campaign",
        .version = @as(u32, 1),
        .identity = identity,
        .name = if (@hasField(@TypeOf(config), "name")) @as(?[]const u8, config.name) else null,
        .base_seed = summary.base_seed,
        .planned_cases = summary.planned_cases,
        .executed_cases = summary.executed_cases,
        .passed_cases = summary.passed_cases,
        .failed_cases = summary.failed_cases,
        .stop_reason = summary.stop_reason,
        .elapsed_ns = summary.elapsed_ns,
        .failures = summary.failures,
        .errors = summary.errors,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    dir.writeFile(io, .{ .sub_path = "campaign.json", .data = bytes, .flags = .{ .exclusive = true } }) catch return error.ArtifactIoFailed;
}

fn now(io: std.Io) u64 {
    return @intCast(@max(std.Io.Clock.awake.now(io).nanoseconds, 0));
}
