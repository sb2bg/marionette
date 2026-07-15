const std = @import("std");
const build_support = @import("src/build_support.zig");

pub const TidyPattern = build_support.TidyPattern;
pub const TidyAllow = build_support.TidyAllow;
pub const TidyExecutableOptions = build_support.TidyExecutableOptions;
pub const TidyStepOptions = build_support.TidyStepOptions;

/// Add Marionette's tidy executable to a consuming build.
pub fn addTidyExecutable(
    b: *std.Build,
    options: TidyExecutableOptions,
) *std.Build.Step.Compile {
    const marionette = b.dependencyFromBuildZig(@This(), .{});
    return build_support.addTidyExecutable(
        b,
        marionette.path("src/main_tidy.zig"),
        options,
    );
}

/// Add a tidy run step whose source belongs to the Marionette dependency.
pub fn addTidyStep(
    b: *std.Build,
    options: TidyStepOptions,
) *std.Build.Step.Run {
    const marionette = b.dependencyFromBuildZig(@This(), .{});
    return build_support.addTidyStep(
        b,
        marionette.path("src/main_tidy.zig"),
        options,
    );
}

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

    // Everything past this point is development-only build graph: tests,
    // examples, validation SUTs, tidy, and release checks. A project that
    // depends on Marionette needs only the modules above, and returning
    // here keeps the lazy validation dependencies from being fetched into
    // consumer projects and keeps their build scripts from running there.
    if (b.pkg_hash.len != 0) return;

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

    if (b.lazyDependency("ochi", .{
        .target = target,
        .optimize = optimize,
    })) |ochi_dep| {
        const ochi_root_mod = ochi_dep.artifact("Ochi").root_module;
        const ochi_store_mod = b.createModule(.{
            .root_source_file = ochi_dep.path("src/Store.zig"),
            .target = target,
            .optimize = optimize,
        });
        const ochi_imports = [_][]const u8{
            "zeit",
            "zint",
            "metrics",
            "logz",
            "logging",
            "tracy",
            "c",
            "encoding",
        };
        for (ochi_imports) |name| {
            ochi_store_mod.addImport(name, ochi_root_mod.import_table.get(name).?);
        }

        const validate_ochi_mod = b.createModule(.{
            .root_source_file = b.path("validation/ochi_store.zig"),
            .target = target,
            .optimize = optimize,
        });
        validate_ochi_mod.addImport("marionette", mod);
        validate_ochi_mod.addImport("ochi_store", ochi_store_mod);
        validate_ochi_mod.addImport("ochi_logging", ochi_root_mod.import_table.get("logging").?);

        const validate_ochi_tests = b.addTest(.{ .root_module = validate_ochi_mod });
        const run_validate_ochi = b.addRunArtifact(validate_ochi_tests);

        const validate_ochi_step = b.step(
            "validate-ochi",
            "Run Ochi's unmodified storage path under Marionette",
        );
        validate_ochi_step.dependOn(&run_validate_ochi.step);
    }

    if (b.lazyDependency("dusty", .{
        .target = target,
        .optimize = optimize,
        .use_tls = false,
    })) |dusty_dep| {
        const validate_dusty_mod = b.createModule(.{
            .root_source_file = b.path("validation/dusty_http.zig"),
            .target = target,
            .optimize = optimize,
        });
        validate_dusty_mod.addImport("marionette", mod);
        validate_dusty_mod.addImport("dusty", dusty_dep.module("dusty"));

        const validate_dusty_tests = b.addTest(.{ .root_module = validate_dusty_mod });
        const run_validate_dusty = b.addRunArtifact(validate_dusty_tests);

        const validate_dusty_step = b.step(
            "validate-dusty",
            "Run the unmodified dusty HTTP client/server under Marionette",
        );
        validate_dusty_step.dependOn(&run_validate_dusty.step);
    }

    if (b.lazyDependency("beanstalkz", .{
        .target = target,
        .optimize = optimize,
    })) |beanstalkz_dep| {
        const validate_beanstalkz_mod = b.createModule(.{
            .root_source_file = b.path("validation/beanstalkz_queue.zig"),
            .target = target,
            .optimize = optimize,
        });
        validate_beanstalkz_mod.addImport("marionette", mod);
        validate_beanstalkz_mod.addImport("beanstalkz", beanstalkz_dep.module("beanstalkz"));

        const validate_beanstalkz_tests = b.addTest(.{ .root_module = validate_beanstalkz_mod });
        const run_validate_beanstalkz = b.addRunArtifact(validate_beanstalkz_tests);

        const validate_beanstalkz_step = b.step(
            "validate-beanstalkz",
            "Run the unmodified beanstalkz queue client under Marionette",
        );
        validate_beanstalkz_step.dependOn(&run_validate_beanstalkz.step);
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

    const validate_kv_compat_mod = b.createModule(.{
        .root_source_file = b.path("validation/kv_compat.zig"),
        .target = target,
        .optimize = optimize,
    });
    validate_kv_compat_mod.addImport("marionette", mod);
    validate_kv_compat_mod.addImport("examples", examples_mod);

    const validate_kv_compat_tests = b.addTest(.{ .root_module = validate_kv_compat_mod });
    const run_validate_kv_compat = b.addRunArtifact(validate_kv_compat_tests);

    const validate_kv_compat_step = b.step(
        "validate-kv-compat",
        "Run the KV compatibility lifecycle (WAL, compaction rename, recovery) under Marionette",
    );
    validate_kv_compat_step.dependOn(&run_validate_kv_compat.step);

    const seed_sweep_count = b.option(
        usize,
        "seed-sweep-count",
        "Number of deterministic seeds to run per nightly scenario",
    ) orelse 1_000;
    const seed_sweep_options = b.addOptions();
    seed_sweep_options.addOption(usize, "count", seed_sweep_count);

    const seed_sweep_mod = b.createModule(.{
        .root_source_file = b.path("validation/nightly_seed_sweep.zig"),
        .target = target,
        .optimize = optimize,
    });
    seed_sweep_mod.addImport("marionette", mod);
    seed_sweep_mod.addImport("examples", examples_mod);
    seed_sweep_mod.addOptions("seed_sweep_options", seed_sweep_options);

    const seed_sweep_tests = b.addTest(.{ .root_module = seed_sweep_mod });
    const run_seed_sweep = b.addRunArtifact(seed_sweep_tests);

    const seed_sweep_step = b.step(
        "seed-sweep",
        "Run the bounded long-running deterministic seed sweep",
    );
    seed_sweep_step.dependOn(&run_seed_sweep.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("marionette", mod);
    tests_mod.addImport("examples", examples_mod);

    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);

    const tidy = build_support.addTidyStep(b, b.path("src/main_tidy.zig"), .{
        .paths = &.{ "src", "examples", "tests", "validation" },
        .extra_allowed = &.{
            .{ .path = "tests/release_symbol_probe.zig", .needle = "std.process" },
            .{ .path = "tests/fiber_overflow_crash.zig", .needle = "std.process" },
            .{ .path = "tests/fiber_overflow_check.zig", .needle = "std.process" },
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
    test_step.dependOn(&run_validate_kv_compat.step);
    test_step.dependOn(&tidy.step);

    const run_tidy_consumer_test = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "test",
        "--build-file",
        b.pathFromRoot("build_tests/tidy_consumer/build.zig"),
        "--cache-dir",
        b.pathFromRoot(".zig-cache/tidy-consumer"),
    });
    test_step.dependOn(&run_tidy_consumer_test.step);

    // The fiber overflow diagnostics are POSIX-only and their subprocess
    // test must execute the crash binary it builds, so wire it only when
    // building natively for a guard-page target.
    const guard_page_target = switch (target.result.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
        else => false,
    };
    if (guard_page_target and target.query.isNative()) {
        const overflow_crash_mod = b.createModule(.{
            .root_source_file = b.path("tests/fiber_overflow_crash.zig"),
            .target = target,
            .optimize = optimize,
        });
        overflow_crash_mod.addImport("marionette", mod);
        const overflow_crash_exe = b.addExecutable(.{
            .name = "marionette-fiber-overflow-crash",
            .root_module = overflow_crash_mod,
        });

        const overflow_check_mod = b.createModule(.{
            .root_source_file = b.path("tests/fiber_overflow_check.zig"),
            .target = target,
            .optimize = optimize,
        });
        const overflow_check_exe = b.addExecutable(.{
            .name = "marionette-fiber-overflow-check",
            .root_module = overflow_check_mod,
        });

        const run_overflow_check = b.addRunArtifact(overflow_check_exe);
        run_overflow_check.addArtifactArg(overflow_crash_exe);
        run_overflow_check.addArg("overflow");
        test_step.dependOn(&run_overflow_check.step);

        const run_non_fiber_check = b.addRunArtifact(overflow_check_exe);
        run_non_fiber_check.addArtifactArg(overflow_crash_exe);
        run_non_fiber_check.addArg("non-fiber-fault");
        test_step.dependOn(&run_non_fiber_check.step);
    }
}
