//! Marionette: deterministic simulation testing for Zig.
//!
//! Public API entry point.

const clock_module = @import("clock.zig");
const run_module = @import("run.zig");

/// Return the clock implementation for a comptime mode.
pub const Clock = clock_module.Clock;

/// Clock backend selected at comptime.
pub const ClockMode = clock_module.Mode;

/// Duration in nanoseconds.
pub const Duration = clock_module.Duration;

/// Wall-clock implementation backed by `std.time`.
pub const ProductionClock = clock_module.ProductionClock;

/// Deterministic fake clock advanced explicitly by tests.
pub const SimClock = clock_module.SimClock;

/// Timestamp in nanoseconds.
pub const Timestamp = clock_module.Timestamp;

/// Default simulated tick size in nanoseconds.
pub const default_tick_ns = clock_module.default_tick_ns;

/// Seeded deterministic random number generator.
pub const Random = @import("random.zig").Random;

/// Deterministic simulation state for Phase 0 tests.
pub const World = @import("world.zig").World;

/// Configuration for `run`.
pub const RunOptions = run_module.RunOptions;

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

test {
    _ = @import("run.zig");
    _ = @import("tidy.zig");
}
