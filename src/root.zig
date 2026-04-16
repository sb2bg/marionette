//! Marionette: deterministic simulation testing for Zig.
//!
//! Public API entry point.

const clock_module = @import("clock.zig");

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

test {
    _ = @import("tidy.zig");
}
