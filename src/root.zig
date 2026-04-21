//! Marionette: deterministic simulation testing for Zig.
//!
//! Public API entry point.

const clock_module = @import("clock.zig");
const env_module = @import("env.zig");
const run_module = @import("run.zig");
const seed_module = @import("seed.zig");

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

/// Default simulated tick size in nanoseconds.
pub const default_tick_ns = clock_module.default_tick_ns;

/// Return the environment implementation for a comptime mode.
pub const Env = env_module.Env;

/// Probability that a BUGGIFY hook fires in simulation.
pub const BuggifyRate = env_module.BuggifyRate;

/// Production composition-root environment.
pub const ProductionEnv = env_module.ProductionEnv;

/// Simulation composition-root environment backed by a `World`.
pub const SimulationEnv = env_module.SimulationEnv;

/// Production random view backed by host entropy.
pub const ProductionRandom = env_module.ProductionRandom;

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

/// Run a scenario twice with the same seed and compare traces.
pub const run = run_module.run;

/// Run a stateful scenario twice with fresh state and compare traces.
pub const runWithState = run_module.runWithState;

/// Errors returned while parsing a user-supplied seed.
pub const SeedParseError = seed_module.SeedParseError;

/// Parse a decimal seed or 40-character Git hash.
pub const parseSeed = seed_module.parseSeed;

test {
    _ = @import("env.zig");
    _ = @import("network.zig");
    _ = @import("run.zig");
    _ = @import("run_types.zig");
    _ = @import("scheduler.zig");
    _ = @import("seed.zig");
    _ = @import("tidy.zig");
}
