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
const trace_summary = @import("trace_summary.zig");

pub const Error = std.mem.Allocator.Error || artifact.Error || trace_summary.TraceSummaryError || error{
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
    /// invocations of a resumed campaign and reduction. Like `max_failures`,
    /// it is checked before every case but the first. With a watchdog, one
    /// case adds at most two `run_timeout_ns`, plus its reduction.
    time_budget_ns: ?u64 = null,
    /// Stop once the campaign has seen this many failing cases.
    max_failures: ?u64 = null,
    /// Reduce the first occurrence of each new reproducible distinct failure
    /// within this budget. Null keeps the original failure only.
    reduction: ?reduce.Options = null,
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

/// Outcome of reducing one distinct failure.
pub const Reduction = struct {
    /// Candidate executions, each including its exact replay.
    attempts: usize,
    original_groups: usize,
    remaining_groups: usize,
    /// No remaining single group can be omitted; false when the attempt
    /// budget ran out first.
    one_minimal: bool,
    /// A smaller verified failure was found. Its evidence is in the failure
    /// directory's `reduced` subdirectory.
    minimized: bool,
    /// Host time spent reducing, outside simulated time.
    elapsed_ns: u64,
};

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
    /// Set when `Options.reduction` reduced this failure.
    reduction: ?Reduction = null,
};

/// Where in a case the runner infrastructure failed.
pub const CasePhase = enum { run, reduction };

/// A case whose runner infrastructure failed, such as a worker result that
/// exceeded its watchdog capacity. The campaign records it and continues.
pub const CaseError = struct {
    case: u64,
    seed: u64,
    error_name: []const u8,
    phase: CasePhase = .run,
};

/// Derived campaign health numbers, also written to the journal.
pub const Metrics = struct {
    /// Executed cases per second of host time spent outside reduction.
    /// Zero until any time has been measured.
    cases_per_second: f64,
    distinct_failures: u64,
    /// Distinct failures with a complete, exactly replayed capsule.
    reproducible_failures: u64,
    /// Distinct failures whose reduction found a smaller verified failure.
    reduced_failures: u64,
    reduction_attempts: u64,
    reduction_elapsed_ns: u64,
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
    /// Why the campaign stopped. Null only in a summary loaded from the
    /// journal of a campaign that is still running or was killed.
    stop_reason: ?StopReason = .completed,
    elapsed_ns: u64 = 0,
    /// Injected faults summed over every case that produced a report.
    faults: trace_summary.FaultCoverage = .{},
    /// Cases whose trace shows no injected fault with an observable effect.
    /// A campaign that passes with this equal to `executed_cases` never
    /// exercised its fault model.
    cases_without_faults: u64 = 0,
    failures: []DistinctFailure = &.{},
    errors: []CaseError = &.{},

    pub fn deinit(self: *Summary) void {
        for (self.failures) |failure| deinitFailure(self.allocator, failure);
        self.allocator.free(self.failures);
        for (self.errors) |case_error| self.allocator.free(case_error.error_name);
        self.allocator.free(self.errors);
        self.* = undefined;
    }

    pub fn metrics(self: *const Summary) Metrics {
        return computeMetrics(self.executed_cases, self.elapsed_ns, self.failures);
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
    faults: trace_summary.FaultCoverage = .{},
    cases_without_faults: u64 = 0,
    /// Derived from the fields above when written; ignored when read.
    metrics: ?Metrics = null,
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
    comptime run.requireKnownConfigFields(@TypeOf(config), "runCampaign", &.{});
    if (options.cases == 0) return error.InvalidCampaignOptions;
    if (options.max_failures) |limit| if (limit == 0) return error.InvalidCampaignOptions;
    if (@hasField(@TypeOf(config), "watchdog")) {
        if (@as(?types.WatchdogOptions, config.watchdog) != null and !@import("watchdog.zig").supported) return error.WatchdogUnavailable;
    }

    var campaign: Campaign = .{
        .allocator = config.allocator,
        .io = options.io,
        .name = if (@hasField(@TypeOf(config), "name")) @as(?[]const u8, config.name) else null,
        .reduction = options.reduction,
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

/// Read a campaign journal without running anything, for example to replay or
/// reduce its retained failures from a fresh process. `dir` is the campaign
/// directory itself. The summary's `start_case` is the next case to run.
pub fn loadSummary(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) Error!Summary {
    var campaign: Campaign = .{
        .allocator = allocator,
        .io = io,
        .name = null,
        .summary = .{ .allocator = allocator, .base_seed = 0, .planned_cases = 0 },
    };
    defer campaign.deinit();
    const journal = try campaign.readJournal(dir);
    defer journal.deinit();
    try campaign.restore(journal.value);
    campaign.summary.base_seed = journal.value.base_seed;
    campaign.summary.planned_cases = journal.value.planned_cases;
    campaign.summary.start_case = journal.value.executed_cases;
    campaign.summary.stop_reason = journal.value.stop_reason;
    return campaign.finish();
}

const Campaign = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    name: ?[]const u8,
    reduction: ?reduce.Options = null,
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
        const journal = try self.readJournal(self.directory.?);
        defer journal.deinit();
        const value = journal.value;
        if (!value.identity.compatible(self.identity) or value.base_seed != self.summary.base_seed or
            value.planned_cases != self.summary.planned_cases) return error.IncompatibleCampaign;
        if (value.executed_cases >= value.planned_cases) return error.CampaignFinished;
        try self.restore(value);
    }

    fn readJournal(self: *Campaign, dir: std.Io.Dir) Error!std.json.Parsed(Journal) {
        const bytes = dir.readFileAlloc(self.io, journal_name, self.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidCampaignJournal,
        };
        defer self.allocator.free(bytes);
        // The parsed journal outlives `bytes`, so it must own its strings.
        const parsed = std.json.parseFromSlice(Journal, self.allocator, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidCampaignJournal,
        };
        errdefer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.format, journal_format) or parsed.value.version != 1) return error.InvalidCampaignJournal;
        return parsed;
    }

    /// Copy journal totals, failures, and errors into owned campaign state.
    fn restore(self: *Campaign, journal: Journal) Error!void {
        self.summary.executed_cases = journal.executed_cases;
        self.summary.passed_cases = journal.passed_cases;
        self.summary.failed_cases = journal.failed_cases;
        self.summary.elapsed_ns = journal.elapsed_ns;
        self.summary.faults = journal.faults;
        self.summary.cases_without_faults = journal.cases_without_faults;
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
            var owned = case_error;
            owned.error_name = try self.allocator.dupe(u8, case_error.error_name);
            self.errors.appendAssumeCapacity(owned);
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
                try self.recordError(case, seed, err, .run);
                self.summary.executed_cases += 1;
                return false;
            },
        };
        // Reduction takes ownership of a new failure's report.
        var owned = true;
        defer if (owned) report.deinit();
        self.summary.executed_cases += 1;
        const coverage = try trace_summary.faultCoverage(switch (report) {
            .passed => |passed| passed.trace,
            .failed => |failed| failed.first_trace,
        });
        self.summary.faults.add(coverage);
        if (!coverage.fired()) self.summary.cases_without_faults += 1;
        if (report == .passed) {
            self.summary.passed_cases += 1;
            return false;
        }
        self.summary.failed_cases += 1;
        const fingerprint = reduce.FailureFingerprint.from(report.failed);
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
            .reproducible = reduce.reproducible(report),
        };
        errdefer deinitFailure(self.allocator, distinct);
        if (self.directory) |dir| {
            distinct.artifact_name = try std.fmt.allocPrint(self.allocator, "failure-{x:0>16}", .{distinct.digest});
            try self.writeArtifacts(dir, &report, distinct.artifact_name.?);
        }
        if (self.reduction != null and distinct.reproducible) {
            owned = false;
            distinct.reduction = try self.reduceFailure(config, case, seed, report, distinct.artifact_name);
        }
        try self.failures.append(self.allocator, distinct);
        return true;
    }

    /// Reduce a new failure, retaining minimized evidence beside the original.
    /// Infrastructure errors are recorded against the case, not fatal.
    fn reduceFailure(self: *Campaign, config: anytype, case: u64, seed: u64, report: types.RunReport, artifact_name: ?[]const u8) Error!?Reduction {
        const started = now(self.io);
        var result = reduce.reduceSeededReport(config, seed, report, self.reduction.?) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.recordError(case, seed, err, .reduction);
                return null;
            },
        };
        defer result.deinit();
        const elapsed = now(self.io) -| started;
        if (result.minimized != null and artifact_name != null) {
            var failure_dir = self.directory.?.openDir(self.io, artifact_name.?, .{}) catch return error.ArtifactIoFailed;
            defer failure_dir.close(self.io);
            try self.writeArtifacts(failure_dir, result.report(), "reduced");
        }
        return .{
            .attempts = result.attempts,
            .original_groups = result.original_groups,
            .remaining_groups = result.remaining_groups,
            .one_minimal = result.one_minimal,
            .minimized = result.minimized != null,
            .elapsed_ns = elapsed,
        };
    }

    fn recordError(self: *Campaign, case: u64, seed: u64, err: anyerror, phase: CasePhase) std.mem.Allocator.Error!void {
        const name = try self.allocator.dupe(u8, @errorName(err));
        errdefer self.allocator.free(name);
        try self.errors.append(self.allocator, .{ .case = case, .seed = seed, .error_name = name, .phase = phase });
    }

    // A campaign killed after writing evidence but before checkpointing it
    // reruns that case on resume. Keep complete evidence; replace partial.
    fn writeArtifacts(self: *Campaign, parent: std.Io.Dir, report: *const types.RunReport, name: []const u8) Error!void {
        const artifact_options: artifact.Options = .{ .io = self.io, .parent = parent, .name = name, .identity = self.identity };
        artifact.write(self.allocator, report, artifact_options) catch |err| switch (err) {
            error.ArtifactAlreadyExists => {
                if (try artifact.isComplete(self.allocator, self.io, parent, name)) return;
                parent.deleteTree(self.io, name) catch return error.ArtifactIoFailed;
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
            .faults = self.summary.faults,
            .cases_without_faults = self.summary.cases_without_faults,
            .metrics = computeMetrics(self.summary.executed_cases, self.summary.elapsed_ns, self.failures.items),
            .failures = self.failures.items,
            .errors = self.errors.items,
        }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(bytes);
        const temporary = journal_name ++ ".tmp";
        dir.writeFile(self.io, .{ .sub_path = temporary, .data = bytes }) catch return error.ArtifactIoFailed;
        std.Io.Dir.rename(dir, temporary, dir, journal_name, self.io) catch return error.ArtifactIoFailed;
    }
};

fn computeMetrics(executed_cases: u64, elapsed_ns: u64, failures: []const DistinctFailure) Metrics {
    var result: Metrics = .{
        .cases_per_second = 0,
        .distinct_failures = failures.len,
        .reproducible_failures = 0,
        .reduced_failures = 0,
        .reduction_attempts = 0,
        .reduction_elapsed_ns = 0,
    };
    for (failures) |failure| {
        if (failure.reproducible) result.reproducible_failures += 1;
        const reduction = failure.reduction orelse continue;
        if (reduction.minimized) result.reduced_failures += 1;
        result.reduction_attempts += reduction.attempts;
        result.reduction_elapsed_ns += reduction.elapsed_ns;
    }
    const case_ns = elapsed_ns -| result.reduction_elapsed_ns;
    if (case_ns != 0) {
        result.cases_per_second = @as(f64, @floatFromInt(executed_cases)) * std.time.ns_per_s / @as(f64, @floatFromInt(case_ns));
    }
    return result;
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

fn now(io: std.Io) u64 {
    return @intCast(@max(std.Io.Clock.awake.now(io).nanoseconds, 0));
}
