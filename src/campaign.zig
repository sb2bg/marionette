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
    InvalidCampaignJournal,
    IncompatibleCampaign,
    CampaignFinished,
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
    /// Host monotonic budget for the whole campaign, including earlier
    /// invocations of a resumed campaign. Like `max_failures`, it is checked
    /// before every case but the first. With a watchdog, one case adds at most
    /// two `run_timeout_ns`.
    time_budget_ns: ?u64 = null,
    /// Stop once the campaign has seen this many failing cases.
    max_failures: ?u64 = null,
    /// Directory for per-failure artifacts and the `campaign.json` journal.
    artifacts: ?Artifacts = null,
};

pub const Artifacts = struct {
    parent: std.Io.Dir,
    /// One relative directory component.
    name: []const u8,
    identity: replay.Identity,
    /// Continue an interrupted or stopped campaign in an existing directory
    /// instead of creating a new one.
    resume_existing: bool = false,
    /// Longest host time between journal checkpoints. New distinct failures
    /// and stops always checkpoint; cases after the last checkpoint rerun on
    /// resume.
    checkpoint_interval_ns: u64 = std.time.ns_per_s,
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

/// Owned campaign totals. Counts include earlier invocations of a resumed
/// campaign; `start_case` is the first case this invocation ran.
pub const Summary = struct {
    allocator: std.mem.Allocator,
    base_seed: u64,
    planned_cases: u64,
    start_case: u64 = 0,
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
        for (self.errors) |case_error| self.allocator.free(case_error.error_name);
        self.allocator.free(self.errors);
        self.* = undefined;
    }
};

const journal_name = "campaign.json";
const journal_format = "marionette.campaign";

/// Serialized campaign state. `stop_reason` is null while the campaign runs or
/// after it was killed; the executed count is the next case to run.
const Journal = struct {
    format: []const u8 = journal_format,
    version: u32 = 1,
    identity: replay.Identity,
    name: ?[]const u8,
    base_seed: u64,
    planned_cases: u64,
    executed_cases: u64,
    passed_cases: u64,
    failed_cases: u64,
    stop_reason: ?StopReason,
    elapsed_ns: u64,
    failures: []const DistinctFailure,
    errors: []const CaseError,
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

    var campaign: Campaign = .{
        .allocator = config.allocator,
        .io = options.io,
        .name = if (@hasField(@TypeOf(config), "name")) @as(?[]const u8, config.name) else null,
        .summary = .{ .allocator = config.allocator, .base_seed = run.configSeed(config), .planned_cases = options.cases },
    };
    defer campaign.deinit();
    if (options.artifacts) |target| try campaign.open(target);

    const prior_elapsed = campaign.summary.elapsed_ns;
    const started = now(options.io);
    var last_checkpoint = started;
    var new_failure = false;
    var case = campaign.summary.executed_cases;
    campaign.summary.start_case = case;
    const stop_reason: StopReason = while (case < options.cases) : (case += 1) {
        // Limits apply before every case but the first, so a fresh campaign
        // runs at least one case and a resumed one may run none.
        if (case > 0) {
            if (options.max_failures) |limit| if (campaign.summary.failed_cases >= limit) break .failure_limit;
            if (options.time_budget_ns) |budget| if (campaign.summary.elapsed_ns >= budget) break .time_budget;
            if (campaign.directory != null and (new_failure or
                now(options.io) -| last_checkpoint >= options.artifacts.?.checkpoint_interval_ns))
            {
                try campaign.checkpoint(null);
                last_checkpoint = now(options.io);
            }
        }
        new_failure = try campaign.runCase(config, case);
        campaign.summary.elapsed_ns = prior_elapsed + (now(options.io) -| started);
    } else .completed;
    campaign.summary.stop_reason = stop_reason;
    if (campaign.directory) |_| try campaign.checkpoint(stop_reason);
    return campaign.finish();
}

const Campaign = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    name: ?[]const u8,
    summary: Summary,
    failures: std.ArrayList(DistinctFailure) = .empty,
    errors: std.ArrayList(CaseError) = .empty,
    directory: ?std.Io.Dir = null,
    identity: replay.Identity = undefined,

    fn deinit(self: *Campaign) void {
        for (self.failures.items) |failure| deinitFailure(self.allocator, failure);
        self.failures.deinit(self.allocator);
        for (self.errors.items) |case_error| self.allocator.free(case_error.error_name);
        self.errors.deinit(self.allocator);
        if (self.directory) |dir| dir.close(self.io);
    }

    /// Move retained state into the returned summary.
    fn finish(self: *Campaign) std.mem.Allocator.Error!Summary {
        var summary = self.summary;
        summary.failures = try self.failures.toOwnedSlice(self.allocator);
        errdefer self.failures = .fromOwnedSlice(summary.failures);
        summary.errors = try self.errors.toOwnedSlice(self.allocator);
        return summary;
    }

    fn open(self: *Campaign, target: Artifacts) Error!void {
        if (target.identity.build.len == 0 or target.identity.sut.len == 0) return error.InvalidReplayIdentity;
        try artifact.validateName(target.name);
        self.identity = target.identity;
        if (target.resume_existing) {
            self.directory = target.parent.openDir(self.io, target.name, .{}) catch return error.InvalidCampaignJournal;
            return self.load();
        }
        target.parent.createDir(self.io, target.name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => return error.ArtifactAlreadyExists,
            else => return error.ArtifactIoFailed,
        };
        self.directory = target.parent.openDir(self.io, target.name, .{}) catch return error.ArtifactIoFailed;
        try self.checkpoint(null);
    }

    fn load(self: *Campaign) Error!void {
        const bytes = self.directory.?.readFileAlloc(self.io, journal_name, self.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidCampaignJournal,
        };
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(Journal, self.allocator, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidCampaignJournal,
        };
        defer parsed.deinit();
        const journal = parsed.value;
        if (!std.mem.eql(u8, journal.format, journal_format) or journal.version != 1) return error.InvalidCampaignJournal;
        if (!journal.identity.compatible(self.identity) or journal.base_seed != self.summary.base_seed or
            journal.planned_cases != self.summary.planned_cases) return error.IncompatibleCampaign;
        if (journal.executed_cases >= journal.planned_cases) return error.CampaignFinished;
        self.summary.executed_cases = journal.executed_cases;
        self.summary.passed_cases = journal.passed_cases;
        self.summary.failed_cases = journal.failed_cases;
        self.summary.elapsed_ns = journal.elapsed_ns;
        try self.failures.ensureTotalCapacity(self.allocator, journal.failures.len);
        for (journal.failures) |failure| {
            var owned = failure;
            owned.fingerprint = try cloneFingerprint(self.allocator, failure.fingerprint);
            owned.artifact_name = null;
            errdefer deinitFailure(self.allocator, owned);
            if (failure.artifact_name) |name| owned.artifact_name = try self.allocator.dupe(u8, name);
            self.failures.appendAssumeCapacity(owned);
        }
        try self.errors.ensureTotalCapacity(self.allocator, journal.errors.len);
        for (journal.errors) |case_error| {
            self.errors.appendAssumeCapacity(.{
                .case = case_error.case,
                .seed = case_error.seed,
                .error_name = try self.allocator.dupe(u8, case_error.error_name),
            });
        }
    }

    /// Run one case and return whether it produced a new distinct failure.
    fn runCase(self: *Campaign, config: anytype, case: u64) Error!bool {
        const seed = run.caseSeed(config, case);
        var report = run.runSeededCase(config, seed) catch |err| switch (err) {
            // Configuration errors would fail every case identically, and host
            // memory exhaustion is not a property of one case.
            error.InvalidSeedSchedule, error.InvalidStateChecks, error.InvalidWatchdogOptions, error.OutOfMemory => |fatal| return fatal,
            else => {
                const name = try self.allocator.dupe(u8, @errorName(err));
                errdefer self.allocator.free(name);
                try self.errors.append(self.allocator, .{ .case = case, .seed = seed, .error_name = name });
                self.summary.executed_cases += 1;
                return false;
            },
        };
        defer report.deinit();
        const new_failure = switch (report) {
            .passed => false,
            .failed => |failure| try self.recordFailure(&report, failure, case, seed),
        };
        switch (report) {
            .passed => self.summary.passed_cases += 1,
            .failed => self.summary.failed_cases += 1,
        }
        self.summary.executed_cases += 1;
        return new_failure;
    }

    fn recordFailure(self: *Campaign, report: *const types.RunReport, failure: types.RunFailure, case: u64, seed: u64) Error!bool {
        const fingerprint = reduce.FailureFingerprint.from(failure);
        for (self.failures.items) |*known| {
            if (known.fingerprint.eql(fingerprint)) {
                known.occurrences += 1;
                return false;
            }
        }
        var distinct: DistinctFailure = .{
            .fingerprint = try cloneFingerprint(self.allocator, fingerprint),
            .digest = fingerprint.digest(),
            .first_case = case,
            .first_seed = seed,
            .reproducible = reduce.reproducible(report.*),
        };
        errdefer deinitFailure(self.allocator, distinct);
        if (self.directory) |dir| {
            distinct.artifact_name = try std.fmt.allocPrint(self.allocator, "failure-{x:0>16}", .{distinct.digest});
            try self.writeFailureArtifacts(dir, report, distinct.artifact_name.?);
        }
        try self.failures.append(self.allocator, distinct);
        return true;
    }

    // A campaign killed after writing a failure but before checkpointing it
    // reruns that case on resume. Keep complete evidence; replace partial.
    fn writeFailureArtifacts(self: *Campaign, dir: std.Io.Dir, report: *const types.RunReport, name: []const u8) Error!void {
        const artifact_options: artifact.Options = .{ .io = self.io, .parent = dir, .name = name, .identity = self.identity };
        artifact.write(self.allocator, report, artifact_options) catch |err| switch (err) {
            error.ArtifactAlreadyExists => {
                const manifest = try std.fmt.allocPrint(self.allocator, "{s}/manifest.json", .{name});
                defer self.allocator.free(manifest);
                if (dir.access(self.io, manifest, .{})) |_| return else |_| {}
                dir.deleteTree(self.io, name) catch return error.ArtifactIoFailed;
                try artifact.write(self.allocator, report, artifact_options);
            },
            else => |other| return other,
        };
    }

    /// Atomically replace the journal so a kill leaves the previous checkpoint.
    fn checkpoint(self: *Campaign, stop_reason: ?StopReason) Error!void {
        const dir = self.directory.?;
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, Journal{
            .identity = self.identity,
            .name = self.name,
            .base_seed = self.summary.base_seed,
            .planned_cases = self.summary.planned_cases,
            .executed_cases = self.summary.executed_cases,
            .passed_cases = self.summary.passed_cases,
            .failed_cases = self.summary.failed_cases,
            .stop_reason = stop_reason,
            .elapsed_ns = self.summary.elapsed_ns,
            .failures = self.failures.items,
            .errors = self.errors.items,
        }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(bytes);
        const temporary = journal_name ++ ".tmp";
        dir.writeFile(self.io, .{ .sub_path = temporary, .data = bytes }) catch return error.ArtifactIoFailed;
        std.Io.Dir.rename(dir, temporary, dir, journal_name, self.io) catch return error.ArtifactIoFailed;
    }
};

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

fn now(io: std.Io) u64 {
    return @intCast(@max(std.Io.Clock.awake.now(io).nanoseconds, 0));
}
