//! Time sources for production and deterministic simulation.
//!
//! Production time is the only place in Marionette that may touch host time.
//! Simulated time is explicit state and only advances when
//! the caller ticks or sleeps the simulated clock.

const std = @import("std");

/// Nanoseconds since an implementation-defined epoch.
///
/// `ProductionClock` uses Zig's host IO clock. `SimClock` uses the simulated
/// world's epoch, which defaults to zero.
pub const Timestamp = u64;

/// Duration in nanoseconds.
pub const Duration = u64;

/// Clock backend selected at comptime.
///
/// Passing the mode at comptime keeps services generic over time while
/// still letting release builds erase unused simulation code.
pub const Mode = enum {
    /// Wall-clock time backed by Zig's host IO clock.
    production,
    /// Deterministic fake time owned by a simulation world.
    simulation,
};

/// Default simulated tick size in nanoseconds.
pub const default_tick_ns: Duration = 1;

/// Return the clock implementation for `mode`.
///
/// Services should usually be generic over `ClockType`, with callers
/// passing `Clock(.production)` or `Clock(.simulation)` at comptime.
pub fn Clock(comptime mode: Mode) type {
    return switch (mode) {
        .production => ProductionClock,
        .simulation => SimClock,
    };
}

/// Production clock backed by the host operating system.
///
/// This is intentionally small: `now()` reads wall-clock time and
/// `sleep()` blocks the current thread. It is the only Marionette clock
/// implementation allowed to read host time.
pub const ProductionClock = struct {
    /// Construct a production clock.
    pub fn init() ProductionClock {
        return .{};
    }

    /// Return the current wall-clock timestamp in nanoseconds.
    pub fn now(_: *const ProductionClock) Timestamp {
        const timestamp = std.Io.Clock.real.now(std.Options.debug_io);
        std.debug.assert(timestamp.nanoseconds >= 0);
        return @intCast(timestamp.nanoseconds);
    }

    /// Block the current thread for `duration_ns` nanoseconds.
    pub fn sleep(_: *ProductionClock, duration_ns: Duration) void {
        std.Io.sleep(
            std.Options.debug_io,
            .fromNanoseconds(duration_ns),
            .awake,
        ) catch unreachable;
    }
};

/// Deterministic clock for simulation tests.
///
/// Time starts at `Options.start_ns` and only advances when the caller
/// invokes `tick()`, `runFor()`, or `sleep()`. Phase 0 has no scheduler,
/// so simulated sleep is an immediate time advance rather than a yield.
pub const SimClock = struct {
    /// Current simulated timestamp in nanoseconds.
    now_ns: Timestamp,
    /// Number of nanoseconds advanced by one `tick()`.
    tick_ns: Duration,

    /// Configuration for a simulated clock.
    pub const Options = struct {
        /// Initial simulated timestamp.
        start_ns: Timestamp = 0,
        /// Nanoseconds per simulation tick. Must be greater than zero.
        tick_ns: Duration = default_tick_ns,
    };

    /// Construct a simulated clock.
    pub fn init(options: Options) SimClock {
        std.debug.assert(options.tick_ns > 0);
        return .{
            .now_ns = options.start_ns,
            .tick_ns = options.tick_ns,
        };
    }

    /// Return the current simulated timestamp in nanoseconds.
    pub fn now(self: *const SimClock) Timestamp {
        return self.now_ns;
    }

    /// Advance simulated time by exactly one configured tick.
    pub fn tick(self: *SimClock) void {
        self.advanceBy(self.tick_ns);
    }

    /// Advance simulated time by `duration_ns`.
    ///
    /// Phase 0 has no scheduler, so sleeping simply moves simulated time
    /// forward. Requiring whole ticks keeps all time movement observable
    /// through the same tick semantics.
    pub fn sleep(self: *SimClock, duration_ns: Duration) void {
        self.runFor(duration_ns);
    }

    /// Advance simulated time by `duration_ns`.
    ///
    /// `duration_ns` must be an exact multiple of this clock's tick size.
    pub fn runFor(self: *SimClock, duration_ns: Duration) void {
        std.debug.assert(duration_ns % self.tick_ns == 0);

        var ticks_remaining = duration_ns / self.tick_ns;
        while (ticks_remaining > 0) : (ticks_remaining -= 1) {
            self.tick();
        }
    }

    fn advanceBy(self: *SimClock, duration_ns: Duration) void {
        std.debug.assert(std.math.maxInt(Timestamp) - self.now_ns >= duration_ns);
        self.now_ns += duration_ns;
    }
};

test "clock: comptime selector chooses implementation" {
    try std.testing.expectEqual(ProductionClock, Clock(.production));
    try std.testing.expectEqual(SimClock, Clock(.simulation));
}

test "clock: sim clock starts at configured time" {
    var clock: SimClock = .init(.{ .start_ns = 42, .tick_ns = 5 });
    try std.testing.expectEqual(@as(Timestamp, 42), clock.now());
}

test "clock: sim clock advances by ticks" {
    var clock: SimClock = .init(.{ .tick_ns = 10 });
    clock.tick();
    clock.tick();
    clock.tick();
    try std.testing.expectEqual(@as(Timestamp, 30), clock.now());
}

test "clock: sim sleep advances by whole ticks" {
    var clock: SimClock = .init(.{ .tick_ns = 4 });
    clock.sleep(12);
    try std.testing.expectEqual(@as(Timestamp, 12), clock.now());
}
