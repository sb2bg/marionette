//! Typed deterministic decision tapes and exact replay validation.

const std = @import("std");

/// Current in-memory decision-tape contract. Durable capsule encoding will
/// version its envelope separately while preserving these semantic fields.
pub const format_version: u32 = 1;

/// The alternatives available at one deterministic choice site.
pub const Alternatives = union(enum) {
    /// Any `u64` value may be selected.
    any_u64,
    /// Exact byte count for one application random call.
    bytes: usize,
    /// The selected value is `0` (`false`) or `1` (`true`).
    boolean,
    /// An unsigned integer in `[0, less_than)` with the declared bit width.
    unsigned_less_than: UnsignedLessThan,

    pub const UnsignedLessThan = struct {
        bits: u16,
        less_than: u64,
    };

    pub fn accepts(self: Alternatives, selected: u64) bool {
        return switch (self) {
            .any_u64, .bytes => true,
            .boolean => selected <= 1,
            .unsigned_less_than => |bounded| bounded.less_than > 0 and selected < bounded.less_than,
        };
    }
};

/// One globally ordered semantic choice.
pub const Decision = struct {
    /// Stable application or simulator-owned semantic choice-site identifier.
    site_id: []const u8,
    /// Simulated timestamp at which the choice occurred.
    logical_time_ns: u64,
    /// Zero-based choice index at this logical timestamp.
    microstep: u64,
    /// Trace event immediately preceding the choice, when one exists.
    preceding_event_index: ?u64,
    /// Typed choice domain presented at the site.
    alternatives: Alternatives,
    /// Selected value encoded as an unsigned scalar.
    selected: u64,
    /// Exact bytes for a `.bytes` choice; selected holds their deterministic digest.
    byte_value: []const u8 = &.{},

    pub fn clone(self: Decision, allocator: std.mem.Allocator) std.mem.Allocator.Error!Decision {
        var result = self;
        result.site_id = try allocator.dupe(u8, self.site_id);
        errdefer allocator.free(result.site_id);
        result.byte_value = try allocator.dupe(u8, self.byte_value);
        return result;
    }

    pub fn deinit(self: Decision, allocator: std.mem.Allocator) void {
        allocator.free(self.site_id);
        allocator.free(self.byte_value);
    }
};

/// A choice request before its selected value is known.
pub const Request = struct {
    site_id: []const u8,
    logical_time_ns: u64,
    microstep: u64,
    preceding_event_index: ?u64,
    alternatives: Alternatives,
};

/// How an engine obtains choices.
pub const Mode = union(enum) {
    /// Append generated choices to a new tape.
    record,
    /// Return and validate choices from this borrowed tape.
    replay: []const Decision,
};

/// Why exact replay stopped at one decision boundary.
pub const DivergenceKind = enum {
    tape_exhausted,
    invalid_tape_entry,
    site_mismatch,
    logical_time_mismatch,
    microstep_mismatch,
    preceding_event_mismatch,
    alternatives_mismatch,
    selected_out_of_range,
    tape_remaining,
};

/// The first exact-replay mismatch. `expected` is a tape entry and `actual`
/// describes the choice requested by the replaying execution.
pub const Divergence = struct {
    kind: DivergenceKind,
    tape_index: usize,
    expected: ?Decision,
    actual: ?Request,

    pub fn clone(self: Divergence, allocator: std.mem.Allocator) std.mem.Allocator.Error!Divergence {
        var cloned: Divergence = .{
            .kind = self.kind,
            .tape_index = self.tape_index,
            .expected = null,
            .actual = null,
        };
        if (self.expected) |expected| {
            cloned.expected = try expected.clone(allocator);
        }
        errdefer if (cloned.expected) |expected| expected.deinit(allocator);
        if (self.actual) |actual| {
            cloned.actual = actual;
            cloned.actual.?.site_id = try allocator.dupe(u8, actual.site_id);
        }
        return cloned;
    }

    pub fn deinit(self: *Divergence, allocator: std.mem.Allocator) void {
        if (self.expected) |expected| expected.deinit(allocator);
        if (self.actual) |actual| allocator.free(actual.site_id);
        self.* = undefined;
    }
};

/// Errors from decision recording or exact replay.
pub const Error = error{
    InvalidDecisionRequest,
    DecisionReplayDiverged,
};

/// An owned decision tape suitable for keeping after a `World` is destroyed.
pub const Tape = struct {
    allocator: ?std.mem.Allocator = null,
    entries: []const Decision = &.{},

    pub fn empty() Tape {
        return .{};
    }

    pub fn clone(allocator: std.mem.Allocator, entries: []const Decision) std.mem.Allocator.Error!Tape {
        const owned = try allocator.alloc(Decision, entries.len);
        errdefer allocator.free(owned);
        for (owned) |*entry| entry.* = undefined;

        var initialized: usize = 0;
        errdefer for (owned[0..initialized]) |entry| entry.deinit(allocator);
        for (entries, 0..) |entry, index| {
            owned[index] = try entry.clone(allocator);
            initialized += 1;
        }
        return .{ .allocator = allocator, .entries = owned };
    }

    pub fn deinit(self: *Tape) void {
        if (self.allocator) |allocator| {
            for (self.entries) |entry| entry.deinit(allocator);
            allocator.free(self.entries);
        }
        self.* = undefined;
    }
};

/// Mutable choice engine owned by one deterministic world.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    recorded: std.ArrayList(Decision) = .empty,
    replay_index: usize = 0,
    last_time_ns: ?u64 = null,
    next_microstep: u64 = 0,
    divergence: ?Divergence = null,

    pub const Checkpoint = struct {
        recorded_len: usize,
        replay_index: usize,
        last_time_ns: ?u64,
        next_microstep: u64,
    };

    pub fn init(allocator: std.mem.Allocator, mode: Mode) Engine {
        return .{ .allocator = allocator, .mode = mode };
    }

    pub fn deinit(self: *Engine) void {
        for (self.recorded.items) |entry| entry.deinit(self.allocator);
        self.recorded.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn checkpoint(self: *const Engine) Checkpoint {
        return .{
            .recorded_len = self.recorded.items.len,
            .replay_index = self.replay_index,
            .last_time_ns = self.last_time_ns,
            .next_microstep = self.next_microstep,
        };
    }

    pub fn rollback(self: *Engine, checkpoint_value: Checkpoint) void {
        std.debug.assert(checkpoint_value.recorded_len <= self.recorded.items.len);
        for (self.recorded.items[checkpoint_value.recorded_len..]) |entry| entry.deinit(self.allocator);
        self.recorded.shrinkRetainingCapacity(checkpoint_value.recorded_len);
        self.replay_index = checkpoint_value.replay_index;
        self.last_time_ns = checkpoint_value.last_time_ns;
        self.next_microstep = checkpoint_value.next_microstep;
        // A fatal replay mismatch is never part of retryable state.
    }

    pub fn request(
        self: *const Engine,
        site_id: []const u8,
        logical_time_ns: u64,
        preceding_event_index: ?u64,
        alternatives: Alternatives,
    ) Error!Request {
        if (!isValidSiteId(site_id) or !validAlternatives(alternatives)) {
            return error.InvalidDecisionRequest;
        }
        const microstep = if (self.last_time_ns != null and self.last_time_ns.? == logical_time_ns)
            self.next_microstep
        else
            0;
        if (microstep == std.math.maxInt(u64)) return error.InvalidDecisionRequest;
        return .{
            .site_id = site_id,
            .logical_time_ns = logical_time_ns,
            .microstep = microstep,
            .preceding_event_index = preceding_event_index,
            .alternatives = alternatives,
        };
    }

    /// Record `generated` or return the exact selected value from the replay
    /// tape. A replay mismatch is latched and never consumes the mismatched
    /// entry.
    pub fn choose(self: *Engine, choice_request: Request, generated: u64) (std.mem.Allocator.Error || Error)!u64 {
        if (choice_request.alternatives == .bytes) return error.InvalidDecisionRequest;
        return self.chooseValue(choice_request, generated, &.{});
    }

    pub fn chooseBytes(self: *Engine, choice_request: Request, buffer: []u8) (std.mem.Allocator.Error || Error)!void {
        if (choice_request.alternatives != .bytes or choice_request.alternatives.bytes != buffer.len) return error.InvalidDecisionRequest;
        const index = self.replay_index;
        _ = try self.chooseValue(choice_request, std.hash.Wyhash.hash(0, buffer), buffer);
        switch (self.mode) {
            .record => {},
            .replay => |entries_value| @memcpy(buffer, entries_value[index].byte_value),
        }
    }

    fn chooseValue(self: *Engine, choice_request: Request, generated: u64, bytes: []const u8) (std.mem.Allocator.Error || Error)!u64 {
        if (self.divergence != null) return error.DecisionReplayDiverged;
        if (!isValidSiteId(choice_request.site_id) or !validAlternatives(choice_request.alternatives) or !choice_request.alternatives.accepts(generated)) return error.InvalidDecisionRequest;

        const selected = switch (self.mode) {
            .record => record: {
                const entry: Decision = .{
                    .site_id = choice_request.site_id,
                    .logical_time_ns = choice_request.logical_time_ns,
                    .microstep = choice_request.microstep,
                    .preceding_event_index = choice_request.preceding_event_index,
                    .alternatives = choice_request.alternatives,
                    .selected = generated,
                    .byte_value = bytes,
                };
                const owned = try entry.clone(self.allocator);
                errdefer owned.deinit(self.allocator);
                try self.recorded.append(self.allocator, owned);
                break :record generated;
            },
            .replay => |tape_entries| replay: {
                if (self.replay_index >= tape_entries.len) {
                    return self.fail(.tape_exhausted, null, choice_request);
                }
                const expected = tape_entries[self.replay_index];
                if (!validDecision(expected)) {
                    return self.fail(.invalid_tape_entry, expected, choice_request);
                }
                if (!expected.alternatives.accepts(expected.selected)) {
                    return self.fail(.selected_out_of_range, expected, choice_request);
                }
                if (!std.mem.eql(u8, expected.site_id, choice_request.site_id)) {
                    return self.fail(.site_mismatch, expected, choice_request);
                }
                if (expected.logical_time_ns != choice_request.logical_time_ns) {
                    return self.fail(.logical_time_mismatch, expected, choice_request);
                }
                if (expected.microstep != choice_request.microstep) {
                    return self.fail(.microstep_mismatch, expected, choice_request);
                }
                if (expected.preceding_event_index != choice_request.preceding_event_index) {
                    return self.fail(.preceding_event_mismatch, expected, choice_request);
                }
                if (!alternativesEqual(expected.alternatives, choice_request.alternatives)) {
                    return self.fail(.alternatives_mismatch, expected, choice_request);
                }
                self.replay_index += 1;
                break :replay expected.selected;
            },
        };

        self.last_time_ns = choice_request.logical_time_ns;
        self.next_microstep = choice_request.microstep + 1;
        return selected;
    }

    /// Require exact replay to consume the whole supplied tape.
    pub fn finishReplay(self: *Engine) Error!void {
        if (self.divergence != null) return error.DecisionReplayDiverged;
        switch (self.mode) {
            .record => {},
            .replay => |tape_entries| {
                if (self.replay_index != tape_entries.len) {
                    const expected = tape_entries[self.replay_index];
                    return self.fail(.tape_remaining, expected, null);
                }
            },
        }
    }

    pub fn entries(self: *const Engine) []const Decision {
        return switch (self.mode) {
            .record => self.recorded.items,
            .replay => |entries_value| entries_value,
        };
    }

    fn fail(
        self: *Engine,
        kind: DivergenceKind,
        expected: ?Decision,
        actual: ?Request,
    ) error{DecisionReplayDiverged} {
        self.divergence = .{
            .kind = kind,
            .tape_index = self.replay_index,
            .expected = expected,
            .actual = actual,
        };
        return error.DecisionReplayDiverged;
    }
};

pub fn isValidSiteId(site_id: []const u8) bool {
    if (site_id.len == 0 or site_id[0] == '.' or site_id[site_id.len - 1] == '.') return false;
    var previous_dot = false;
    for (site_id) |byte| {
        const valid = (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or byte == '_' or byte == '.';
        if (!valid) return false;
        if (byte == '.' and previous_dot) return false;
        previous_dot = byte == '.';
    }
    return true;
}

pub fn validDecision(entry: Decision) bool {
    if (!isValidSiteId(entry.site_id) or !validAlternatives(entry.alternatives)) return false;
    return switch (entry.alternatives) {
        .bytes => |len| len == entry.byte_value.len and entry.selected == std.hash.Wyhash.hash(0, entry.byte_value),
        else => entry.byte_value.len == 0,
    };
}

fn validAlternatives(alternatives: Alternatives) bool {
    return switch (alternatives) {
        .any_u64, .boolean, .bytes => true,
        .unsigned_less_than => |bounded| bounded.bits > 0 and bounded.bits <= 64 and bounded.less_than > 0 and (bounded.bits == 64 or bounded.less_than <= (@as(u64, 1) << @intCast(bounded.bits))),
    };
}

fn alternativesEqual(a: Alternatives, b: Alternatives) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .any_u64, .boolean => true,
        .bytes => |len| len == b.bytes,
        .unsigned_less_than => |a_bounded| {
            const b_bounded = b.unsigned_less_than;
            return a_bounded.bits == b_bounded.bits and a_bounded.less_than == b_bounded.less_than;
        },
    };
}

test "decision: record captures typed logical ordering" {
    var engine = Engine.init(std.testing.allocator, .record);
    defer engine.deinit();

    const first = try engine.request("scheduler.select", 10, 4, .{ .unsigned_less_than = .{ .bits = 64, .less_than = 3 } });
    try std.testing.expectEqual(@as(u64, 2), try engine.choose(first, 2));
    const second = try engine.request("network.drop", 10, 5, .boolean);
    try std.testing.expectEqual(@as(u64, 1), try engine.choose(second, 1));
    const third = try engine.request("disk.latency", 20, 8, .any_u64);
    _ = try engine.choose(third, 99);

    try std.testing.expectEqual(@as(usize, 3), engine.entries().len);
    try std.testing.expectEqual(@as(u64, 0), engine.entries()[0].microstep);
    try std.testing.expectEqual(@as(u64, 1), engine.entries()[1].microstep);
    try std.testing.expectEqual(@as(u64, 0), engine.entries()[2].microstep);
}

test "decision: exact replay returns tape selections" {
    const entries = [_]Decision{.{
        .site_id = "scheduler.select",
        .logical_time_ns = 10,
        .microstep = 0,
        .preceding_event_index = 4,
        .alternatives = .{ .unsigned_less_than = .{ .bits = 64, .less_than = 3 } },
        .selected = 2,
    }};
    var engine = Engine.init(std.testing.allocator, .{ .replay = &entries });
    defer engine.deinit();

    const choice_request = try engine.request("scheduler.select", 10, 4, .{ .unsigned_less_than = .{ .bits = 64, .less_than = 3 } });
    try std.testing.expectEqual(@as(u64, 2), try engine.choose(choice_request, 0));
    try engine.finishReplay();
}

test "decision: first replay divergence is retained without consumption" {
    const entries = [_]Decision{.{
        .site_id = "scheduler.select",
        .logical_time_ns = 10,
        .microstep = 0,
        .preceding_event_index = 4,
        .alternatives = .{ .unsigned_less_than = .{ .bits = 64, .less_than = 3 } },
        .selected = 2,
    }};
    var engine = Engine.init(std.testing.allocator, .{ .replay = &entries });
    defer engine.deinit();

    const choice_request = try engine.request("network.drop", 10, 4, .{ .unsigned_less_than = .{ .bits = 64, .less_than = 3 } });
    try std.testing.expectError(error.DecisionReplayDiverged, engine.choose(choice_request, 0));
    try std.testing.expectEqual(DivergenceKind.site_mismatch, engine.divergence.?.kind);
    try std.testing.expectEqual(@as(usize, 0), engine.replay_index);
    try std.testing.expectError(error.DecisionReplayDiverged, engine.finishReplay());
}

test "decision: checkpoint rolls recording and replay positions back" {
    var recording = Engine.init(std.testing.allocator, .record);
    defer recording.deinit();
    const record_checkpoint = recording.checkpoint();
    const record_request = try recording.request("world.random_u64", 0, 0, .any_u64);
    _ = try recording.choose(record_request, 42);
    recording.rollback(record_checkpoint);
    try std.testing.expectEqual(@as(usize, 0), recording.entries().len);

    const entries = [_]Decision{.{
        .site_id = "world.random_u64",
        .logical_time_ns = 0,
        .microstep = 0,
        .preceding_event_index = 0,
        .alternatives = .any_u64,
        .selected = 42,
    }};
    var replaying = Engine.init(std.testing.allocator, .{ .replay = &entries });
    defer replaying.deinit();
    const replay_checkpoint = replaying.checkpoint();
    const replay_request = try replaying.request("world.random_u64", 0, 0, .any_u64);
    _ = try replaying.choose(replay_request, 7);
    replaying.rollback(replay_checkpoint);
    try std.testing.expectEqual(@as(usize, 0), replaying.replay_index);
}

test "decision: recording allocation failure does not consume a microstep" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var engine = Engine.init(failing.allocator(), .record);
    defer engine.deinit();

    const first_request = try engine.request("scheduler.select", 10, 4, .any_u64);
    try std.testing.expectError(error.OutOfMemory, engine.choose(first_request, 42));
    try std.testing.expectEqual(@as(usize, 0), engine.entries().len);
    try std.testing.expectEqual(@as(?u64, null), engine.last_time_ns);
    try std.testing.expectEqual(@as(u64, 0), engine.next_microstep);

    engine.allocator = std.testing.allocator;
    const retry_request = try engine.request("scheduler.select", 10, 4, .any_u64);
    try std.testing.expectEqual(@as(u64, 42), try engine.choose(retry_request, 42));
    try std.testing.expectEqual(@as(u64, 0), engine.entries()[0].microstep);
}

fn cloneTapeWithAllocator(allocator: std.mem.Allocator) !void {
    const entries = [_]Decision{
        .{
            .site_id = "scheduler.select",
            .logical_time_ns = 0,
            .microstep = 0,
            .preceding_event_index = 0,
            .alternatives = .{ .unsigned_less_than = .{ .bits = 64, .less_than = 2 } },
            .selected = 1,
        },
        .{
            .site_id = "network.drop",
            .logical_time_ns = 0,
            .microstep = 1,
            .preceding_event_index = 1,
            .alternatives = .boolean,
            .selected = 0,
        },
    };
    var tape = try Tape.clone(allocator, &entries);
    defer tape.deinit();
}

test "decision: owned tape cloning is leak-free across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        cloneTapeWithAllocator,
        .{},
    );
}

fn cloneDivergenceWithAllocator(allocator: std.mem.Allocator) !void {
    const divergence: Divergence = .{
        .kind = .site_mismatch,
        .tape_index = 3,
        .expected = .{
            .site_id = "scheduler.select",
            .logical_time_ns = 10,
            .microstep = 2,
            .preceding_event_index = 8,
            .alternatives = .{ .unsigned_less_than = .{ .bits = 64, .less_than = 2 } },
            .selected = 1,
        },
        .actual = .{
            .site_id = "scheduler.wake",
            .logical_time_ns = 10,
            .microstep = 2,
            .preceding_event_index = 8,
            .alternatives = .{ .unsigned_less_than = .{ .bits = 64, .less_than = 2 } },
        },
    };
    var cloned = try divergence.clone(allocator);
    defer cloned.deinit(allocator);
}

test "decision: divergence cloning is leak-free across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        cloneDivergenceWithAllocator,
        .{},
    );
}
