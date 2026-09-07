//! Caller-owned host I/O. Never reach for ambient host filesystem authority.
const std = @import("std");
const types = @import("run_types.zig");
const replay = @import("replay.zig");
const reduce = @import("reduce.zig");
pub const Error = error{ OutOfMemory, InvalidArtifactPath, InvalidReplayIdentity, ArtifactAlreadyExists, ArtifactIoFailed, ArtifactEncodingFailed };
pub const Options = struct {
    io: std.Io,
    parent: std.Io.Dir,
    /// Single relative directory component. Existing directories are refused.
    name: []const u8,
    identity: replay.Identity,
    include_passes: bool = false,
};

pub fn write(allocator: std.mem.Allocator, report: *const types.RunReport, options: Options) Error!void {
    if (report.* == .passed and !options.include_passes) return;
    if (options.name.len == 0 or std.mem.eql(u8, options.name, ".") or std.mem.eql(u8, options.name, "..")) return error.InvalidArtifactPath;
    for (options.name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '_') return error.InvalidArtifactPath;
    }
    if (options.identity.build.len == 0 or options.identity.sut.len == 0) return error.InvalidReplayIdentity;
    const capsule: ?[]u8 = replay.Capsule.encode(allocator, report, options.identity) catch |err| switch (err) {
        error.IncompleteDecisionTape, error.UnreproducibleRun => null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ArtifactEncodingFailed,
    };
    defer if (capsule) |bytes| allocator.free(bytes);
    const failed = report.* == .failed;
    const trace = if (failed) report.failed.first_trace else report.passed.trace;
    const metadata = try std.json.Stringify.valueAlloc(allocator, .{
        .format = "marionette.artifacts",
        .version = @as(u32, 1),
        .complete = true,
        .outcome = if (failed) "failed" else "passed",
        .identity = options.identity,
        .options = if (failed) report.failed.options else report.passed.options,
        .simulate = if (failed) report.failed.simulate_options else report.passed.simulate_options,
        .failure = if (failed) @as(?reduce.FailureFingerprint, reduce.FailureFingerprint.from(report.failed)) else null,
        .fingerprint = if (failed) @as(?u64, reduce.FailureFingerprint.from(report.failed).digest()) else null,
        .capsule_available = capsule != null,
        .tape_complete = if (failed) report.failed.tape_complete else report.passed.tape_complete,
        .replay_divergence = if (failed) report.failed.replay_divergence else null,
        .second_error_name = if (failed) report.failed.second_error_name else null,
        .second_check_name = if (failed) report.failed.second_check_name else null,
        .capsule_unavailable_reason = if (capsule != null) @as(?[]const u8, null) else if (!(if (failed) report.failed.tape_complete else report.passed.tape_complete)) "incomplete_tape" else "unreproducible_run",
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(metadata);
    options.parent.createDir(options.io, options.name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.ArtifactAlreadyExists,
        else => return error.ArtifactIoFailed,
    };
    var dir = options.parent.openDir(options.io, options.name, .{}) catch return error.ArtifactIoFailed;
    defer dir.close(options.io);
    try writeFile(dir, options.io, "trace.txt", trace);
    if (failed and report.failed.second_trace.len != 0) try writeFile(dir, options.io, "second-trace.txt", report.failed.second_trace);
    if (capsule) |bytes| try writeFile(dir, options.io, "replay.json", bytes);
    // Manifest publication marks a completed directory; partial I/O leaves no
    // complete manifest and never overwrites a previous run's artifacts.
    try writeFile(dir, options.io, "manifest.json", metadata);
}
fn writeFile(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) Error!void {
    dir.writeFile(io, .{ .sub_path = path, .data = bytes, .flags = .{ .exclusive = true } }) catch return error.ArtifactIoFailed;
}
