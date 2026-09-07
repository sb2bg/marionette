//! Bounded delta debugging over semantic decision/action site groups.
const std = @import("std");
const run = @import("run.zig");
const types = @import("run_types.zig");

/// Failure identity excludes seed, trace positions, and decision counts.
/// Equality compares complete fields; the digest is only an artifact label.
pub const FailureFingerprint = struct {
    kind: types.RunFailureKind,
    error_name: ?[]const u8,
    check_name: ?[]const u8,

    pub fn from(failure: types.RunFailure) FailureFingerprint {
        return .{ .kind = failure.kind, .error_name = failure.error_name, .check_name = failure.check_name };
    }
    pub fn eql(a: FailureFingerprint, b: FailureFingerprint) bool {
        return a.kind == b.kind and textEqual(a.error_name, b.error_name) and textEqual(a.check_name, b.check_name);
    }
    pub fn digest(self: FailureFingerprint) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(@tagName(self.kind));
        for ([_]?[]const u8{ self.error_name, self.check_name }) |value| {
            hash.update(&.{@intFromBool(value != null)});
            if (value) |bytes| {
                var len: [8]u8 = undefined;
                std.mem.writeInt(u64, &len, @intCast(bytes.len), .little);
                hash.update(&len);
                hash.update(bytes);
            }
        }
        return hash.final();
    }
    fn textEqual(a: ?[]const u8, b: ?[]const u8) bool {
        if (a) |value| return b != null and std.mem.eql(u8, value, b.?);
        return b == null;
    }
};

pub const Options = struct { max_attempts: usize = 256 };
pub const Result = struct {
    original: types.RunReport,
    minimized: ?types.RunReport = null,
    attempts: usize = 0,
    original_groups: usize = 0,
    remaining_groups: usize = 0,
    /// True only after exhausting all single-group deletions in the final set.
    one_minimal: bool = false,

    pub fn report(self: *const Result) *const types.RunReport {
        return if (self.minimized) |*value| value else &self.original;
    }
    pub fn deinit(self: *Result) void {
        if (self.minimized) |*value| value.deinit();
        self.original.deinit();
        self.* = undefined;
    }
};

fn reproducible(report: types.RunReport) bool {
    return report == .failed and report.failed.tape_complete and
        report.failed.second_trace.len == 0 and report.failed.replay_divergence == null and
        report.failed.kind != .determinism_mismatch and report.failed.kind != .replay_diverged;
}

/// Reduce whole semantic sites (including `action.*` groups) to zero/false/zero
/// bytes. Candidates record fresh decisions and must pass exact second-run
/// replay and preserve the original full fingerprint before acceptance.
/// The config is the ordinary runSimCase config, including its watchdog budget.
pub fn reduceSimCase(config: anytype, options: Options) !Result {
    const allocator = config.allocator;
    var result: Result = .{ .original = try run.runSimCase(config) };
    errdefer result.deinit();
    if (!reproducible(result.original)) return error.ExpectedReproducibleFailure;
    const fingerprint = FailureFingerprint.from(result.original.failed);
    const tape = result.original.failed.decision_tape.entries;
    var sites: std.ArrayList([]const u8) = .empty;
    defer sites.deinit(allocator);
    for (tape) |entry| {
        const nonzero = if (entry.alternatives == .bytes) for (entry.byte_value) |byte| {
            if (byte != 0) break true;
        } else false else entry.selected != 0;
        if (!nonzero) continue;
        var exists = false;
        for (sites.items) |site| {
            if (std.mem.eql(u8, site, entry.site_id)) {
                exists = true;
                break;
            }
        }
        if (!exists) try sites.append(allocator, entry.site_id);
    }
    result.original_groups = sites.items.len;
    result.remaining_groups = sites.items.len;
    const disabled = try allocator.alloc(bool, sites.items.len);
    defer allocator.free(disabled);
    @memset(disabled, false);
    var active: std.ArrayList(usize) = .empty;
    defer active.deinit(allocator);
    var omitted: std.ArrayList([]const u8) = .empty;
    defer omitted.deinit(allocator);
    var granularity: usize = 2;
    while (true) {
        active.clearRetainingCapacity();
        for (disabled, 0..) |removed, index| if (!removed) {
            try active.append(allocator, index);
        };
        if (active.items.len == 0) {
            result.one_minimal = true;
            break;
        }
        const chunk = std.math.divCeil(usize, active.items.len, @min(granularity, active.items.len)) catch unreachable;
        var accepted = false;
        var start: usize = 0;
        while (start < active.items.len) : (start += chunk) {
            if (result.attempts == options.max_attempts) return result;
            const end = @min(start + chunk, active.items.len);
            omitted.clearRetainingCapacity();
            for (disabled, 0..) |removed, index| if (removed) {
                try omitted.append(allocator, sites.items[index]);
            };
            for (active.items[start..end]) |index| try omitted.append(allocator, sites.items[index]);
            var candidate = try run.runReductionCandidate(config, tape, omitted.items);
            result.attempts += 1;
            if (reproducible(candidate) and fingerprint.eql(FailureFingerprint.from(candidate.failed))) {
                if (result.minimized) |*previous| previous.deinit();
                result.minimized = candidate;
                for (active.items[start..end]) |index| disabled[index] = true;
                result.remaining_groups -= end - start;
                granularity = @max(2, granularity -| 1);
                accepted = true;
                break;
            }
            candidate.deinit();
        }
        if (accepted) continue;
        if (granularity >= active.items.len) {
            result.one_minimal = true;
            break;
        }
        granularity = @min(active.items.len, granularity *| 2);
    }
    return result;
}
