//! Test suite entry point.

pub const net_differential = @import("net_differential.zig");
pub const trace_summary = @import("trace_summary.zig");

test {
    _ = @import("regressions_070.zig");
}

test {
    _ = @import("replay_capsule.zig");
}
