//! Reproduction inputs supplied by the build (`reproOptions` in build.zig).

const replay_module = @import("replay.zig");

/// A replay identity whose build component is the consumer's Git revision
/// from `reproOptions`. `options` is `@import("marionette_repro")`.
pub fn identity(comptime options: type, sut: []const u8) replay_module.Identity {
    return .{ .build = options.build_id, .sut = sut };
}

/// The seed passed as `-Dmarionette-seed`, if any.
pub fn rerunSeed(comptime options: type) ?u64 {
    return options.seed;
}

/// The capsule path passed as `-Dmarionette-capsule`, if any.
pub fn capsulePath(comptime options: type) ?[]const u8 {
    return options.capsule;
}
