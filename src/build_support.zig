//! Build helpers for Marionette users.

const std = @import("std");
const tidy = @import("tidy.zig");

pub const TidyPattern = tidy.Pattern;
pub const TidyAllow = tidy.Allow;

pub const TidyExecutableOptions = struct {
    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.OptimizeMode = null,
};

pub const TidyStepOptions = struct {
    paths: []const []const u8,
    extra_patterns: []const TidyPattern = &.{},
    extra_allowed: []const TidyAllow = &.{},
    tidy_exe: ?*std.Build.Step.Compile = null,
    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.OptimizeMode = null,
};

/// Add the `marionette-tidy` executable to a build.
pub fn addTidyExecutable(
    b: *std.Build,
    options: TidyExecutableOptions,
) *std.Build.Step.Compile {
    const tidy_mod = b.createModule(.{
        .root_source_file = b.path("src/main_tidy.zig"),
        .target = options.target orelse b.graph.host,
        .optimize = options.optimize orelse .Debug,
    });

    return b.addExecutable(.{
        .name = "marionette-tidy",
        .root_module = tidy_mod,
    });
}

/// Add a run step that fails when banned non-deterministic calls are found.
pub fn addTidyStep(b: *std.Build, options: TidyStepOptions) *std.Build.Step.Run {
    const tidy_exe = options.tidy_exe orelse addTidyExecutable(b, .{
        .target = options.target,
        .optimize = options.optimize,
    });
    const run = b.addRunArtifact(tidy_exe);
    for (options.extra_patterns) |pattern| {
        run.addArg(switch (pattern.match) {
            .exact => "--ban",
            .prefix => "--ban-prefix",
        });
        run.addArg(pattern.needle);
        run.addArg(pattern.reason);
    }
    for (options.extra_allowed) |allow| {
        if (allow.needle) |needle| {
            run.addArg("--allow-pattern");
            run.addArg(allow.path);
            run.addArg(needle);
        } else {
            run.addArg("--allow");
            run.addArg(allow.path);
        }
    }
    run.addArgs(options.paths);
    return run;
}
