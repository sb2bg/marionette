const std = @import("std");
const build_support = @import("src/build_support.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("marionette", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const release_mod = b.addModule("marionette_release", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const examples_mod = b.createModule(.{
        .root_source_file = b.path("examples/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    examples_mod.addImport("marionette", mod);

    const example_tests = b.addTest(.{ .root_module = examples_mod });
    const run_example_tests = b.addRunArtifact(example_tests);

    const run_examples_mod = b.createModule(.{
        .root_source_file = b.path("src/main_run.zig"),
        .target = target,
        .optimize = optimize,
    });
    run_examples_mod.addImport("marionette", mod);
    run_examples_mod.addImport("examples", examples_mod);

    const run_examples_exe = b.addExecutable(.{
        .name = "marionette-run",
        .root_module = run_examples_mod,
    });
    b.installArtifact(run_examples_exe);

    const run_examples_cmd = b.addRunArtifact(run_examples_exe);
    if (b.args) |args| run_examples_cmd.addArgs(args);

    const run_examples_step = b.step("run-example", "Run a Marionette example by seed");
    run_examples_step.dependOn(&run_examples_cmd.step);

    const release_probe_mod = b.createModule(.{
        .root_source_file = b.path("tests/release_symbol_probe.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    release_probe_mod.addImport("marionette", release_mod);

    const release_probe_exe = b.addExecutable(.{
        .name = "marionette-release-symbol-probe",
        .root_module = release_probe_mod,
    });

    const check_release_symbols_cmd = b.addSystemCommand(&.{
        "sh",
        "tests/check_release_symbols.sh",
    });
    check_release_symbols_cmd.addArtifactArg(release_probe_exe);

    const check_release_symbols_step = b.step(
        "check-release-symbols",
        "Verify production release binary does not contain simulation-only symbols",
    );
    check_release_symbols_step.dependOn(&check_release_symbols_cmd.step);

    if (b.lazyDependency("xitdb", .{
        .target = target,
        .optimize = optimize,
    })) |xitdb_dep| {
        const validate_xitdb_mod = b.createModule(.{
            .root_source_file = b.path("validation/xitdb_durability.zig"),
            .target = target,
            .optimize = optimize,
        });
        validate_xitdb_mod.addImport("marionette", mod);
        validate_xitdb_mod.addImport("xitdb", xitdb_dep.module("xitdb"));

        const validate_xitdb_tests = b.addTest(.{ .root_module = validate_xitdb_mod });
        const run_validate_xitdb = b.addRunArtifact(validate_xitdb_tests);

        const validate_xitdb_step = b.step("validate-xitdb", "Run xitdb under Marionette");
        validate_xitdb_step.dependOn(&run_validate_xitdb.step);
    }

    if (b.lazyDependency("mailbox", .{
        .target = target,
        .optimize = optimize,
    })) |mailbox_dep| {
        const validate_mailbox_mod = b.createModule(.{
            .root_source_file = b.path("validation/mailbox_concurrency.zig"),
            .target = target,
            .optimize = optimize,
        });
        validate_mailbox_mod.addImport("marionette", mod);
        validate_mailbox_mod.addImport("mailbox", mailbox_dep.module("mailbox"));

        const validate_mailbox_tests = b.addTest(.{ .root_module = validate_mailbox_mod });
        const run_validate_mailbox = b.addRunArtifact(validate_mailbox_tests);

        const validate_mailbox_step = b.step("validate-mailbox", "Run Mailbox under Marionette");
        validate_mailbox_step.dependOn(&run_validate_mailbox.step);
    }

    const validate_bounded_queue_mod = b.createModule(.{
        .root_source_file = b.path("validation/bounded_queue_concurrency.zig"),
        .target = target,
        .optimize = optimize,
    });
    validate_bounded_queue_mod.addImport("marionette", mod);

    const validate_bounded_queue_tests = b.addTest(.{ .root_module = validate_bounded_queue_mod });
    const run_validate_bounded_queue = b.addRunArtifact(validate_bounded_queue_tests);

    const validate_bounded_queue_step = b.step(
        "validate-bounded-queue",
        "Run the cooperative bounded-queue capability validation",
    );
    validate_bounded_queue_step.dependOn(&run_validate_bounded_queue.step);

    const validate_std_io_net_kv_mod = b.createModule(.{
        .root_source_file = b.path("validation/std_io_net_kv.zig"),
        .target = target,
        .optimize = optimize,
    });
    validate_std_io_net_kv_mod.addImport("marionette", mod);
    validate_std_io_net_kv_mod.addImport("examples", examples_mod);
    run_examples_mod.addImport("std_io_net_kv_validation", validate_std_io_net_kv_mod);

    const validate_std_io_net_kv_tests = b.addTest(.{
        .root_module = validate_std_io_net_kv_mod,
    });
    const run_validate_std_io_net_kv = b.addRunArtifact(validate_std_io_net_kv_tests);

    const validate_std_io_net_kv_step = b.step(
        "validate-std-io-net-kv",
        "Run the std.Io.net KV capability validation",
    );
    validate_std_io_net_kv_step.dependOn(&run_validate_std_io_net_kv.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("marionette", mod);
    tests_mod.addImport("examples", examples_mod);

    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);

    const tidy = build_support.addTidyStep(b, .{
        .paths = &.{ "src", "examples", "tests", "validation" },
        .extra_allowed = &.{
            .{ .path = "tests/release_symbol_probe.zig", .needle = "std.process" },
        },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_example_tests.step);
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_validate_bounded_queue.step);
    test_step.dependOn(&run_validate_std_io_net_kv.step);
    test_step.dependOn(&tidy.step);
}
