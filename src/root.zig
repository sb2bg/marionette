//! Marionette: deterministic simulation testing for Zig.
//!
//! Public API entry point.

const clock_module = @import("clock.zig");
const disk_module = @import("disk.zig");
const env_module = @import("env.zig");
const run_module = @import("run.zig");
const seed_module = @import("seed.zig");
const trace_summary_module = @import("trace_summary.zig");

/// Return the clock implementation for a comptime mode.
pub const Clock = clock_module.Clock;

/// Clock backend selected at comptime.
pub const ClockMode = clock_module.Mode;

/// Duration in nanoseconds.
pub const Duration = clock_module.Duration;

/// Wall-clock implementation backed by Zig's host IO clock.
pub const ProductionClock = clock_module.ProductionClock;

/// Deterministic fake clock advanced explicitly by tests.
pub const SimClock = clock_module.SimClock;

/// Timestamp in nanoseconds.
pub const Timestamp = clock_module.Timestamp;

/// Stable simulated node/process identifier.
pub const NodeId = @import("network.zig").NodeId;

/// Errors returned by unstable network runtime validation.
pub const UnstableNetworkError = @import("network.zig").NetworkError;

/// Default simulated tick size in nanoseconds.
pub const default_tick_ns = clock_module.default_tick_ns;

/// App-facing disk capability.
pub const Disk = disk_module.Disk;

/// Simulator-control disk capability.
pub const DiskControl = disk_module.DiskControl;

/// Deterministic in-memory disk simulator.
pub const SimDisk = disk_module.SimDisk;

/// Production disk adapter backed by a real root directory.
pub const RealDisk = disk_module.RealDisk;

/// Configuration for one deterministic disk simulator.
pub const DiskOptions = disk_module.DiskOptions;

/// Fault rates and corruption controls for one deterministic disk simulator.
pub const DiskFaultOptions = disk_module.DiskFaultOptions;

/// Errors returned by deterministic disk operations.
pub const DiskError = disk_module.DiskError;

/// Concrete app-facing environment capability bundle.
pub const Env = env_module.Env;

/// App-facing clock capability.
pub const EnvClock = env_module.Clock;

/// Errors returned by clock capabilities.
pub const ClockError = env_module.ClockError;

/// App-facing random capability.
pub const EnvRandom = env_module.Random;

/// Errors returned by random capabilities.
pub const EnvRandomError = env_module.RandomError;

/// App-facing trace capability.
pub const Tracer = env_module.Tracer;

/// Errors returned by trace capabilities.
pub const TracerError = env_module.TracerError;

/// Simulator-control capability bundle.
pub const SimControl = env_module.SimControl;

/// Probability that a BUGGIFY hook fires in simulation.
pub const BuggifyRate = env_module.BuggifyRate;

/// Errors returned by BUGGIFY runtime validation.
pub const BuggifyError = env_module.BuggifyError;

/// Concrete app-facing environment capability bundle.
pub const AppEnv = env_module.AppEnv;

/// Errors returned by app-facing environment authorities.
pub const AppEnvError = env_module.AppEnvError;

/// Seeded deterministic random number generator.
pub const Random = @import("random.zig").Random;

/// Deterministic simulation state for Phase 0 tests.
pub const World = @import("world.zig").World;

/// Unstable fixed-capacity deterministic event queue for examples.
///
/// This is a Phase 0 scheduler sketch, not a stable public scheduler API.
pub const UnstableEventQueue = @import("scheduler.zig").EventQueue;

/// Errors returned by unstable fixed-capacity event queues.
pub const UnstableEventQueueError = @import("scheduler.zig").EventQueueError;

/// Unstable deterministic network primitive for examples and early scheduler work.
pub const UnstableNetwork = @import("network.zig").UnstableNetwork;

/// Unstable simulator wrapper that owns one deterministic network packet core.
pub const UnstableNetworkSimulation = @import("network.zig").NetworkSimulation;

/// Fixed topology and per-path capacity for one unstable network instance.
pub const UnstableNetworkOptions = @import("network.zig").NetworkOptions;

/// Configuration for `run`.
pub const RunOptions = run_module.RunOptions;

/// Replay-visible typed attribute attached to a run.
pub const RunAttribute = run_module.RunAttribute;

/// Replay-visible scalar attribute value.
pub const RunAttributeValue = run_module.RunAttributeValue;

/// Build one replay-visible typed attribute from a scalar value.
pub const runAttribute = run_module.runAttribute;

/// Build run attributes from a scalar-only run profile struct.
pub const runAttributesFrom = run_module.runAttributesFrom;

/// Named scenario check run by `run`.
pub const Check = run_module.Check;

/// Named scenario check over user-owned scenario state.
pub const StateCheck = run_module.StateCheck;

/// Successful deterministic scenario result.
pub const RunResult = run_module.RunResult;

/// Data-bearing scenario failure.
pub const RunFailure = run_module.RunFailure;

/// Failure kind captured by the runner.
pub const RunFailureKind = run_module.RunFailureKind;

/// Result of `run`: either a verified replay or a failure report.
pub const RunReport = run_module.RunReport;

/// Errors returned by the deterministic scenario runner itself.
pub const RunError = run_module.RunError;

/// Errors returned while writing deterministic trace records.
pub const TraceError = run_module.TraceError;

/// One structured trace field written by `World.recordFields`.
pub const TraceField = @import("world.zig").TraceField;

/// Replay-safe scalar trace value.
pub const TraceValue = @import("world.zig").TraceValue;

/// Build one structured trace field.
pub const traceField = @import("world.zig").traceField;

/// Run a scenario twice with the same seed and compare traces.
pub const run = run_module.run;

/// Run a stateful scenario twice with fresh state and compare traces.
pub const runWithState = run_module.runWithState;

/// Run a stateful scenario with fallible initialization and world-owned teardown.
pub const runWithStateInit = run_module.runWithStateInit;

/// Run a stateful scenario with fallible initialization and explicit teardown.
pub const runWithStateLifecycle = run_module.runWithStateLifecycle;

/// Run a scenario through the struct-config runner.
pub const runCase = run_module.runCase;

/// Expect a struct-config scenario to pass.
pub const expectPass = run_module.expectPass;

/// Expect a struct-config scenario to fail.
pub const expectFailure = run_module.expectFailure;

/// Expect a struct-config scenario to pass over many seeds.
pub const expectFuzz = run_module.expectFuzz;

/// Errors returned by expectation helpers.
pub const ExpectRunError = run_module.ExpectRunError;

/// Errors returned while parsing a user-supplied seed.
pub const SeedParseError = seed_module.SeedParseError;

/// Parse a decimal seed or 40-character Git hash.
pub const parseSeed = seed_module.parseSeed;

/// Owned deterministic summary of one Marionette trace.
pub const Summary = trace_summary_module.Summary;

/// Errors returned while summarizing a trace.
pub const TraceSummaryError = trace_summary_module.TraceSummaryError;

/// Build an owned summary from line-oriented trace bytes.
pub const summarize = trace_summary_module.summarize;

test {
    _ = @import("disk.zig");
    _ = @import("env.zig");
    _ = @import("network.zig");
    _ = @import("run.zig");
    _ = @import("run_types.zig");
    _ = @import("scheduler.zig");
    _ = @import("seed.zig");
    _ = @import("tidy.zig");
    _ = @import("trace_summary.zig");
}
