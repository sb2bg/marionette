//! Composition-root environment for production and simulation authorities.
//!
//! Application code should receive an environment from its caller instead of
//! auto-detecting whether it is running in production or simulation.

const std = @import("std");

const clock_module = @import("clock.zig");
const World = @import("world.zig").World;

/// Environment selected at comptime.
pub fn Env(comptime mode: clock_module.Mode) type {
    return switch (mode) {
        .production => ProductionEnv,
        .simulation => SimulationEnv,
    };
}

/// Production random authority backed by host entropy.
///
pub const ProductionRandom = struct {
    source: std.Random.IoSource,

    /// Construct a production random authority.
    pub fn init() ProductionRandom {
        return .{ .source = .{ .io = std.Options.debug_io } };
    }

    /// Draw an untraced `u64` from host entropy.
    pub fn randomU64(self: *const ProductionRandom) !u64 {
        return self.source.interface().int(u64);
    }

    /// Draw an untraced boolean from host entropy.
    pub fn boolean(self: *const ProductionRandom) !bool {
        return self.source.interface().boolean();
    }

    /// Draw an unbiased integer in the range `0 <= value < less_than`.
    pub fn intLessThan(self: *const ProductionRandom, comptime T: type, less_than: T) !T {
        return self.source.interface().intRangeLessThan(T, 0, less_than);
    }
};

/// Production environment for the application composition root.
pub const ProductionEnv = struct {
    clock_authority: clock_module.ProductionClock,
    random_authority: ProductionRandom,

    pub const Options = struct {};

    /// Construct a production environment.
    pub fn init(_: Options) ProductionEnv {
        return .{
            .clock_authority = .init(),
            .random_authority = .init(),
        };
    }

    /// Return the production clock authority.
    pub fn clock(self: *ProductionEnv) *clock_module.ProductionClock {
        return &self.clock_authority;
    }

    /// Return the production random authority.
    pub fn random(self: *ProductionEnv) *ProductionRandom {
        return &self.random_authority;
    }
};

/// Simulation environment backed by a `World`.
pub const SimulationEnv = struct {
    world: *World,

    /// Construct a simulation environment from a world.
    pub fn init(world: *World) SimulationEnv {
        return .{ .world = world };
    }

    /// Return the world's simulated clock authority.
    pub fn clock(self: *SimulationEnv) *clock_module.SimClock {
        return self.world.clock();
    }

    /// Return the world's traced random authority.
    pub fn random(self: *SimulationEnv) World.TracedRandom {
        return self.world.tracedRandom();
    }

    /// Advance the backing world by one simulation tick.
    pub fn tick(self: *SimulationEnv) !void {
        try self.world.tick();
    }

    /// Advance the backing world by a duration measured in nanoseconds.
    pub fn runFor(self: *SimulationEnv, duration_ns: clock_module.Duration) !void {
        try self.world.runFor(duration_ns);
    }

    /// Record one trace event through the backing world.
    pub fn record(self: *SimulationEnv, comptime fmt: []const u8, args: anytype) !void {
        try self.world.record(fmt, args);
    }
};

test "env: comptime selector chooses implementation" {
    try std.testing.expectEqual(ProductionEnv, Env(.production));
    try std.testing.expectEqual(SimulationEnv, Env(.simulation));
}

test "env: simulation routes through world authorities" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var env = SimulationEnv.init(&world);
    try env.tick();
    _ = try env.random().intLessThan(u64, 100);

    try std.testing.expectEqual(@as(clock_module.Timestamp, 10), env.clock().now());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.tick now_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.random_int_less_than") != null);
}

test "env: production exposes production authorities" {
    var env = ProductionEnv.init(.{});

    _ = env.clock().now();
    _ = try env.random().intLessThan(u8, 10);
}
