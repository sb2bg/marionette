//! Explicit time state for deterministic simulation.

const std = @import("std");

/// Nanoseconds since the simulated world's epoch, which defaults to zero.
pub const Timestamp = u64;

/// Duration in nanoseconds.
pub const Duration = u64;

/// Default simulated tick size in nanoseconds.
pub const default_tick_ns: Duration = 1;

/// Deterministic clock for simulation tests.
///
/// Time starts at `Options.start_ns` and only advances when the caller
/// invokes `tick()`, `runFor()`, or `sleep()`. This low-level clock does not
/// suspend tasks; scheduler-backed `std.Io` waits park through the scheduler.
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
    /// Sleeping directly on `SimClock` moves simulated time forward.
    /// Requiring whole ticks keeps all time movement observable through the
    /// same tick semantics.
    pub fn sleep(self: *SimClock, duration_ns: Duration) void {
        self.runFor(duration_ns);
    }

    /// Advance simulated time by `duration_ns`.
    ///
    /// `duration_ns` must be an exact multiple of this clock's tick size.
    /// The advance is one jump: this clock has no per-tick side effects, so
    /// stepping tick by tick would be observably identical but
    /// O(duration / tick_ns), which breaks large time jumps at fine tick
    /// resolutions.
    pub fn runFor(self: *SimClock, duration_ns: Duration) void {
        std.debug.assert(duration_ns % self.tick_ns == 0);
        self.advanceBy(duration_ns);
    }

    /// Round a duration up to the next representable simulation tick.
    pub fn ceilDuration(self: *const SimClock, duration_ns: Duration) Duration {
        const remainder = duration_ns % self.tick_ns;
        if (remainder == 0) return duration_ns;
        return std.math.add(Duration, duration_ns, self.tick_ns - remainder) catch
            @panic("simulated duration exceeds clock range");
    }

    fn advanceBy(self: *SimClock, duration_ns: Duration) void {
        std.debug.assert(std.math.maxInt(Timestamp) - self.now_ns >= duration_ns);
        self.now_ns += duration_ns;
    }
};

test "clock: sim clock starts at configured time" {
    var clock: SimClock = .init(.{ .start_ns = 42, .tick_ns = 5 });
    try std.testing.expectEqual(@as(Timestamp, 42), clock.now());
}

test "clock: duration ceiling follows tick resolution" {
    const clock: SimClock = .init(.{ .tick_ns = 10 });
    try std.testing.expectEqual(@as(Duration, 0), clock.ceilDuration(0));
    try std.testing.expectEqual(@as(Duration, 10), clock.ceilDuration(10));
    try std.testing.expectEqual(@as(Duration, 20), clock.ceilDuration(15));
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
