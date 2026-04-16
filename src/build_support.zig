//! Build helpers for Marionette users.

const std = @import("std");

pub const TidyExecutableOptions = struct {
    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.OptimizeMode = null,
};

pub const TidyStepOptions = struct {
    paths: []const []const u8,
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
    run.addArgs(options.paths);
    return run;
}
