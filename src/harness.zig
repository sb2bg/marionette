//! One typed harness built once from an app, a scenario, and its checks.
//!
//! ```zig
//! const H = mar.Harness(.{ .init = App.init, .scenario = App.scenario, .checks = &checks });
//! var report = try H.run(allocator, .{ .seed = 42 });
//! var replayed = try H.replay(allocator, &capsule, identity);
//! ```
//!
//! Every entry point (run, expectations, fuzz, replay, reduction, campaigns,
//! and crash-point sweeps) uses the same initializer, scenario, and checks, so
//! a capsule can never be replayed against different checks. Simulation
//! options default to the harness's `simulate`, or to `.{}`.

const std = @import("std");

const campaign_module = @import("campaign.zig");
const clock_module = @import("clock.zig");
const crash_points_module = @import("crash_points.zig");
const reduce_module = @import("reduce.zig");
const replay_module = @import("replay.zig");
const run_module = @import("run.zig");
const run_types = @import("run_types.zig");
const seed_module = @import("seed.zig");
const World = @import("world.zig").World;

pub fn Harness(comptime spec: anytype) type {
    const Spec = @TypeOf(spec);
    comptime {
        if (!@hasField(Spec, "init")) @compileError("Harness spec requires `init`");
        if (!@hasField(Spec, "scenario")) @compileError("Harness spec requires `scenario`");
        for (std.meta.fieldNames(Spec)) |name| {
            const known = std.mem.eql(u8, name, "init") or std.mem.eql(u8, name, "scenario") or
                std.mem.eql(u8, name, "checks") or std.mem.eql(u8, name, "simulate") or
                std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "capture");
            if (!known) @compileError("Harness spec has unknown field `" ++ name ++ "`");
        }
    }
    const App = run_module.appTypeFromSimInit(spec.init);
    const Case = run_module.SimCase(App);
    const Check = run_module.StateCheck(Case);
    const has_capture = @hasField(Spec, "capture");
    const Outcome = if (has_capture) CaptureOutcome(spec.capture) else void;
    const outcome_has_deinit = if (has_capture) std.meta.hasMethod(Outcome, "deinit") else false;

    const Capturing = struct {
        threadlocal var allocator: ?std.mem.Allocator = null;
        threadlocal var slot: ?Outcome = null;

        fn release() void {
            if (slot) |*outcome| {
                if (comptime outcome_has_deinit) outcome.deinit();
                slot = null;
            }
        }

        fn scenario(case: *Case) anyerror!void {
            const Return = @typeInfo(@TypeOf(spec.scenario)).@"fn".return_type.?;
            if (comptime @typeInfo(Return) == .error_union) try spec.scenario(case) else spec.scenario(case);
            const capture_allocator = allocator orelse return;
            // The runner executes twice; keep the latest outcome.
            release();
            slot = try spec.capture(case, capture_allocator);
        }
    };
    const scenario_fn = if (has_capture) Capturing.scenario else spec.scenario;

    return struct {
        /// What `capture` returns, or `void` without one.
        pub const CapturedOutcome = Outcome;

        /// A report plus the outcome `capture` extracted from the app state
        /// at the end of the scenario. The outcome is null when the scenario
        /// failed or ran in a watchdog worker. Call `deinit`.
        pub const Captured = struct {
            report: run_types.RunReport,
            outcome: ?Outcome,

            pub fn deinit(self: *Captured) void {
                self.report.deinit();
                if (self.outcome) |*outcome| {
                    if (comptime outcome_has_deinit) outcome.deinit();
                }
                self.* = undefined;
            }
        };

        /// Run once and return the report with the captured outcome. The
        /// harness spec must define `capture: fn (*SimCase(App),
        /// std.mem.Allocator) !Outcome`; an outcome with `deinit` owns its
        /// allocations.
        pub fn runCapture(allocator: std.mem.Allocator, options: Options) !Captured {
            if (!has_capture) @compileError("runCapture requires a `capture` field in the Harness spec");
            Capturing.allocator = allocator;
            defer Capturing.allocator = null;
            errdefer Capturing.release();
            const report = try run(allocator, options);
            const outcome = Capturing.slot;
            Capturing.slot = null;
            return .{ .report = report, .outcome = if (report == .passed) outcome else blk: {
                if (outcome) |value| {
                    var owned = value;
                    if (comptime outcome_has_deinit) owned.deinit();
                }
                break :blk null;
            } };
        }

        pub const AppType = App;
        pub const CaseType = Case;
        pub const checks: []const Check = if (@hasField(Spec, "checks")) spec.checks else &.{};
        pub const default_simulate: World.SimulateOptions = if (@hasField(Spec, "simulate")) spec.simulate else .{};
        pub const default_name: ?[]const u8 = if (@hasField(Spec, "name")) spec.name else null;

        /// Per-run options. Everything else comes from the harness.
        pub const Options = struct {
            seed: u64 = 0,
            seed_schedule: []const seed_module.SeedCutover = &.{},
            start_ns: clock_module.Timestamp = 0,
            tick_ns: clock_module.Duration = clock_module.default_tick_ns,
            /// Overrides the harness's run name.
            name: ?[]const u8 = null,
            tags: []const []const u8 = &.{},
            attributes: []const run_types.RunAttribute = &.{},
            watchdog: ?run_types.WatchdogOptions = null,
            check_resources: bool = false,
            /// Overrides the harness's simulation options for this run.
            simulate: ?World.SimulateOptions = null,
        };

        fn config(allocator: std.mem.Allocator, options: Options) Config {
            return .{
                .allocator = allocator,
                .simulate = options.simulate orelse default_simulate,
                .seed = options.seed,
                .seed_schedule = options.seed_schedule,
                .start_ns = options.start_ns,
                .tick_ns = options.tick_ns,
                .name = options.name orelse default_name,
                .tags = options.tags,
                .attributes = options.attributes,
                .watchdog = options.watchdog,
                .check_resources = options.check_resources,
            };
        }

        const Config = struct {
            allocator: std.mem.Allocator,
            simulate: World.SimulateOptions,
            comptime init: @TypeOf(spec.init) = spec.init,
            comptime scenario: @TypeOf(scenario_fn) = scenario_fn,
            comptime checks: []const Check = checks,
            seed: u64,
            seed_schedule: []const seed_module.SeedCutover,
            start_ns: clock_module.Timestamp,
            tick_ns: clock_module.Duration,
            name: ?[]const u8,
            tags: []const []const u8,
            attributes: []const run_types.RunAttribute,
            watchdog: ?run_types.WatchdogOptions,
            check_resources: bool,
        };

        const ArtifactConfig = struct {
            allocator: std.mem.Allocator,
            simulate: World.SimulateOptions,
            comptime init: @TypeOf(spec.init) = spec.init,
            comptime scenario: @TypeOf(scenario_fn) = scenario_fn,
            comptime checks: []const Check = checks,
            seed: u64,
            seed_schedule: []const seed_module.SeedCutover,
            start_ns: clock_module.Timestamp,
            tick_ns: clock_module.Duration,
            name: ?[]const u8,
            tags: []const []const u8,
            attributes: []const run_types.RunAttribute,
            watchdog: ?run_types.WatchdogOptions,
            check_resources: bool,
            artifacts: @import("artifact.zig").Options,
        };

        /// Run once (with its exact second execution) and return the report.
        pub fn run(allocator: std.mem.Allocator, options: Options) run_module.RunError!run_types.RunReport {
            return run_module.runSimCase(config(allocator, options));
        }

        /// Run and write replayable artifacts for a failure.
        pub fn runWithArtifacts(
            allocator: std.mem.Allocator,
            options: Options,
            artifacts: @import("artifact.zig").Options,
        ) run_module.RunError!run_types.RunReport {
            const base = config(allocator, options);
            const with: ArtifactConfig = .{
                .allocator = base.allocator,
                .simulate = base.simulate,
                .seed = base.seed,
                .seed_schedule = base.seed_schedule,
                .start_ns = base.start_ns,
                .tick_ns = base.tick_ns,
                .name = base.name,
                .tags = base.tags,
                .attributes = base.attributes,
                .watchdog = base.watchdog,
                .check_resources = base.check_resources,
                .artifacts = artifacts,
            };
            return run_module.runSimCase(with);
        }

        /// Expect the run to pass; prints the failure summary otherwise.
        pub fn expectPass(allocator: std.mem.Allocator, options: Options) run_module.ExpectRunError!void {
            return run_module.expectSimPass(config(allocator, options));
        }

        /// Expect the run to fail as `expectation` describes.
        pub fn expectFailure(
            allocator: std.mem.Allocator,
            options: Options,
            expectation: run_types.FailureExpectation,
        ) run_module.ExpectRunError!void {
            var report = try run(allocator, options);
            defer report.deinit();
            switch (report) {
                .passed => return error.ExpectedRunFailure,
                .failed => |failure| if (!expectation.matches(failure)) {
                    failure.print();
                    return error.UnexpectedRunFailure;
                },
            }
        }

        pub const FuzzOptions = struct {
            /// Deterministic seeds derived from `Options.seed`.
            seeds: usize,
            /// Run exactly this seed instead, as a failure reported it.
            /// Wire it to `-Dmarionette-seed` with `addReproOptions`.
            rerun: ?u64 = null,
        };

        /// Run many deterministic seeds, or rerun one. A failure prints its
        /// summary and the build option that reruns it.
        pub fn fuzz(allocator: std.mem.Allocator, options: Options, fuzz_options: FuzzOptions) run_module.ExpectRunError!void {
            if (fuzz_options.rerun) |seed| {
                var rerun_options = options;
                rerun_options.seed = seed;
                return expectPass(allocator, rerun_options);
            }
            if (fuzz_options.seeds == 0) return error.InvalidSeedCount;
            for (0..fuzz_options.seeds) |iteration| {
                var iteration_options = options;
                iteration_options.seed = run_module.fuzzSeed(options.seed, iteration);
                var report = try run(allocator, iteration_options);
                defer report.deinit();
                switch (report) {
                    .passed => {},
                    .failed => |failure| {
                        std.debug.print(
                            "marionette harness fuzz failure: seed={} iteration={}; rerun with -Dmarionette-seed={}\n",
                            .{ iteration_options.seed, iteration, iteration_options.seed },
                        );
                        failure.print();
                        return error.ExpectedRunPass;
                    },
                }
            }
        }

        /// Replay a capsule against this harness's initializer, scenario,
        /// and checks.
        pub fn replay(
            allocator: std.mem.Allocator,
            capsule: *const replay_module.Capsule,
            identity: replay_module.Identity,
        ) !run_types.RunReport {
            return run_module.replaySimCase(.{
                .allocator = allocator,
                .init = spec.init,
                .scenario = scenario_fn,
                .checks = checks,
            }, capsule, identity);
        }

        /// Run, then reduce the failure's semantic decisions within a budget.
        pub fn reduce(
            allocator: std.mem.Allocator,
            options: Options,
            reduction: reduce_module.Options,
        ) !reduce_module.Result {
            return reduce_module.reduceSimCase(config(allocator, options), reduction);
        }

        /// Reduce a retained capsule in this process.
        pub fn reduceCapsule(
            allocator: std.mem.Allocator,
            capsule: *const replay_module.Capsule,
            identity: replay_module.Identity,
            reduction: reduce_module.Options,
        ) !reduce_module.Result {
            return reduce_module.reduceCapsule(.{
                .allocator = allocator,
                .init = spec.init,
                .scenario = scenario_fn,
                .checks = checks,
            }, capsule, identity, reduction);
        }

        /// Run an unattended seed campaign.
        pub fn campaign(
            allocator: std.mem.Allocator,
            options: Options,
            campaign_options: campaign_module.Options,
        ) campaign_module.Error!campaign_module.Summary {
            return campaign_module.runCampaign(config(allocator, options), campaign_options);
        }

        /// Sweep disk crash points across the scenario's armed region.
        pub fn sweepCrashPoints(
            allocator: std.mem.Allocator,
            options: Options,
            sweep: crash_points_module.Options,
        ) crash_points_module.Error!crash_points_module.Result {
            return crash_points_module.sweepCrashPoints(config(allocator, options), sweep);
        }

        /// Expect every crash point to pass.
        pub fn expectCrashPointsPass(
            allocator: std.mem.Allocator,
            options: Options,
            sweep: crash_points_module.Options,
        ) !void {
            return crash_points_module.expectCrashPointsPass(config(allocator, options), sweep);
        }
    };
}

fn CaptureOutcome(comptime capture: anytype) type {
    const Return = @typeInfo(@TypeOf(capture)).@"fn".return_type.?;
    return switch (@typeInfo(Return)) {
        .error_union => |info| info.payload,
        else => Return,
    };
}
