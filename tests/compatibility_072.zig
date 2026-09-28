//! Serialization fixtures captured from v0.7.1 before the 0.7.2 cleanup.
const std = @import("std");
const mar = @import("marionette");
const examples = @import("examples");

// Synthetic identity makes wire-format comparisons portable. These fixtures
// are comparison data, not permission to replay an artifact across builds.
const identity: mar.ReplayIdentity = .{
    .build = "v0.7.1-format-fixture",
    .sut = "compatibility_072",
    .zig = "fixture",
    .target = "fixture",
    .optimize = "fixture",
};

const Process = struct {
    io: std.Io,
    file: std.Io.File,
    pub fn init(env: mar.Env) !@This() {
        const file = try std.Io.Dir.cwd().createFile(env.io(), "state", .{ .truncate = false, .read = true });
        return .{ .io = env.io(), .file = file };
    }
    pub fn deinit(self: *@This()) void {
        self.file.close(self.io);
    }
};
const App = struct {
    pub fn init(sim: mar.Sim) !@This() {
        _ = try sim.manageProcess(Process, 0, Process.init);
        _ = try sim.manageProcess(Process, 1, Process.init);
        return .{};
    }
    pub fn scenario(case: *mar.SimCase(@This())) !void {
        try case.sim.killProcess(0);
        try case.sim.restartProcess(0);
        try case.control().disk.crash();
        try case.control().disk.restart();
        try case.sim.restartProcess(0);
        try case.sim.restartProcess(1);
        try case.control().process.setDynamics(1, .{
            .crash_rate = .{ .numerator = 1, .denominator = 2 },
            .restart_rate = .always(),
        });
        try case.control().runFor(8);
        try case.sim.transitionToLiveness(&.{ 0, 1 });
    }
};

fn fixture(comptime name: []const u8, actual: []const u8) !void {
    try std.testing.expectEqualStrings(@embedFile("fixtures/0.7.1/" ++ name), actual);
}

fn compareArtifacts(comptime name: []const u8, report: *const mar.RunReport) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try mar.writeRunArtifacts(std.testing.allocator, report, .{
        .io = std.testing.io,
        .parent = tmp.dir,
        .name = "run",
        .identity = identity,
        .include_passes = true,
    });
    inline for (.{ "trace.txt", "replay.json", "manifest.json" }) |file| {
        const bytes = try tmp.dir.readFileAlloc(std.testing.io, "run/" ++ file, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(bytes);
        try fixture(name ++ "-" ++ file, bytes);
    }
}

test "0.7.2 compatibility: managed lifecycle, fault choices and artifact bytes" {
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 72,
        .name = "managed lifecycle",
        .tags = &.{ "compatibility", "process" },
        .attributes = &.{mar.runAttribute("version", @as(u64, 1))},
        .seed_schedule = &.{.{ .seed = 71, .at = .{ .sim_time_ns = 3 } }},
        .simulate = mar.World.SimulateOptions{ .network = .{ .nodes = 2 } },
        .init = App.init,
        .scenario = App.scenario,
        .check_resources = true,
    });
    defer report.deinit();
    try std.testing.expect(report == .passed);
    try compareArtifacts("process", &report);
}

test "0.7.2 compatibility: reduction choices, property identity and artifact bytes" {
    var reduced = try examples.reduction.run(std.testing.allocator, 1234);
    defer reduced.deinit();
    try compareArtifacts("reduced", reduced.report());
}
