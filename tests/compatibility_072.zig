//! Serialization fixtures. `fixtures/0.7.1` was captured before the 0.7.2
//! cleanup under the `portable_v1` disk contract and is kept unchanged as
//! historical evidence; `fixtures/0.8.3` is the same scenarios under
//! `portable_v2` revision 2. `fixtures/0.8.3-revision3` preserves those
//! scenarios under the corrected crash ordering. Every difference between
//! consecutive sets is classified below.
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
    try std.testing.expectEqualStrings(@embedFile("fixtures/0.8.3-revision3/" ++ name), actual);
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

/// Each portable_v1 expectation that portable_v2 changes, by reason. Event
/// numbers, decision `preceding_event_index` values, and event counts shift
/// with the removed lines; the identity's `disk_version` moves from 1 to 2.
/// Nothing else in the artifacts may differ.
const ClassifiedChange = struct {
    reason: []const u8,
    v1: []const []const u8,
    v2: []const []const u8,
};

const classified_changes = [_]ClassifiedChange{
    .{
        .reason = "the disk contract has a new identity",
        .v1 = &.{"disk.model contract=portable_v1 version=1 sector_size=4096 torn_write=sector_prefix reorder=crash_global_reverse lifecycle=commit_pending"},
        .v2 = &.{"disk.model contract=portable_v2 version=2 sector_size=4096 torn_write=sector_prefix reorder=crash_global_reverse lifecycle=identity_pending"},
    },
    .{
        .reason = "an empty creation is a namespace record, not a zero-length pending write",
        .v1 = &.{
            "disk.crash_write op=2 path=state offset=0 len=0 result=landed",
            "disk.crash pending_writes=1 landed=1 lost=0 torn=0 reordered=0 pending_metadata=1 metadata_kept=1 metadata_lost=0",
        },
        .v2 = &.{"disk.crash pending_writes=0 landed=0 lost=0 torn=0 reordered=0 orphaned=0 pending_metadata=1 metadata_kept=1 metadata_lost=0"},
    },
};

fn traceBodyWithout(
    allocator: std.mem.Allocator,
    trace: []const u8,
    comptime side: enum { v1, v2 },
) !std.ArrayList([]const u8) {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, trace, '\n');
    next_line: while (iterator.next()) |line| {
        // Strip the event number; renumbering is a consequence, not a change.
        const body = if (std.mem.startsWith(u8, line, "event="))
            line[(std.mem.indexOfScalar(u8, line, ' ') orelse line.len - 1) + 1 ..]
        else
            line;
        for (classified_changes) |change| {
            const declared = switch (side) {
                .v1 => change.v1,
                .v2 => change.v2,
            };
            for (declared) |expected| {
                if (std.mem.eql(u8, body, expected)) continue :next_line;
            }
        }
        try lines.append(allocator, body);
    }
    return lines;
}

fn expectOnlyClassifiedChanges(comptime name: []const u8) !void {
    const allocator = std.testing.allocator;
    var v1 = try traceBodyWithout(allocator, @embedFile("fixtures/0.7.1/" ++ name ++ "-trace.txt"), .v1);
    defer v1.deinit(allocator);
    var v2 = try traceBodyWithout(allocator, @embedFile("fixtures/0.8.3/" ++ name ++ "-trace.txt"), .v2);
    defer v2.deinit(allocator);
    try std.testing.expectEqual(v1.items.len, v2.items.len);
    for (v1.items, v2.items) |old, new| try std.testing.expectEqualStrings(old, new);
}

test "0.8.3 compatibility: portable_v2 changes only classified 0.7.1 expectations" {
    try expectOnlyClassifiedChanges("process");
    try expectOnlyClassifiedChanges("reduced");
}

test "0.8.3 compatibility: a portable_v1 capsule is rejected, not reinterpreted" {
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, @embedFile("fixtures/0.7.1/process-replay.json"));
    defer capsule.deinit();
    var current = identity;
    current.disk_version = mar.disk_semantic_version;
    try std.testing.expectError(error.IncompatibleDiskModel, capsule.validateIdentity(current));
    var pinned = current;
    pinned.disk_version = 1;
    try capsule.validateIdentity(pinned);
}

test "0.8.3 compatibility: unchanged workloads differ only in disk revision" {
    inline for (.{ "process", "reduced" }) |name| {
        inline for (.{ "-trace.txt", "-replay.json", "-manifest.json" }) |suffix| {
            const previous = @embedFile("fixtures/0.8.3/" ++ name ++ suffix);
            const current = @embedFile("fixtures/0.8.3-revision3/" ++ name ++ suffix);
            const model = try std.mem.replaceOwned(u8, std.testing.allocator, current, "contract=portable_v2 version=3", "contract=portable_v2 version=2");
            defer std.testing.allocator.free(model);
            const compact = try std.mem.replaceOwned(u8, std.testing.allocator, model, "\"disk_version\":3", "\"disk_version\":2");
            defer std.testing.allocator.free(compact);
            const pretty = try std.mem.replaceOwned(u8, std.testing.allocator, compact, "\"disk_version\": 3", "\"disk_version\": 2");
            defer std.testing.allocator.free(pretty);
            try std.testing.expectEqualStrings(previous, pretty);
        }
    }
}
