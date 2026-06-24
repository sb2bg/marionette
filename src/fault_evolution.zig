//! Private contract for subsystems whose seeded faults evolve with time.

const clock_module = @import("clock.zig");

/// One fixed simulator subsystem participating in time-based fault evolution.
///
/// Implementations may draw only through the world's traced random authority.
/// `evolve_at_boundary` runs after the boundary's clock event is traced, and
/// every resulting state transition must emit its own trace event.
pub const Participant = struct {
    ptr: *anyopaque,
    evolve_at_boundary: *const fn (*anyopaque) anyerror!void,
    next_boundary_before_or_at: *const fn (*anyopaque, clock_module.Timestamp) anyerror!?clock_module.Timestamp,
    finish_run_for: *const fn (*anyopaque) anyerror!void,

    pub fn evolveAtBoundary(self: Participant) !void {
        try self.evolve_at_boundary(self.ptr);
    }

    pub fn nextBoundaryBeforeOrAt(
        self: Participant,
        end_ns: clock_module.Timestamp,
    ) !?clock_module.Timestamp {
        return try self.next_boundary_before_or_at(self.ptr, end_ns);
    }

    pub fn finishRunFor(self: Participant) !void {
        try self.finish_run_for(self.ptr);
    }
};
