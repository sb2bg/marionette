//! Network faults as handles.
//!
//! Every disruption the harness injects (a partition, an isolated node, a cut
//! link, a degraded link, a clog, or an automatic partition) is one active
//! fault with an id, a disruption mode, an optional expiry, and the set of
//! directed paths it covers. Healing one fault leaves the others in place.
//!
//! Composition rule: for one directed path, the most disruptive active mode
//! decides the packet's fate, `drop` before `reject` before `hold`; `slow`
//! delays from every covering fault add together. Among faults of the deciding
//! mode, the oldest (lowest id) is credited in traces.

const std = @import("std");

const clock_module = @import("../clock.zig");
const fault_module = @import("../fault.zig");
const types = @import("types.zig");

const BuggifyRate = fault_module.BuggifyRate;
const NodeId = types.NodeId;

/// How a fault disrupts the packets on the paths it covers.
pub const FaultMode = enum {
    /// Packets vanish. Senders see silence and recover only by their own
    /// retransmission and timeouts.
    drop,
    /// Packets wait at the fault and continue, in order, when it heals.
    hold,
    /// Packets are delayed by the fault's extra latency.
    slow,
    /// Packets are refused: the sender's host receives an ICMP-style
    /// "host unreachable" signal one path latency later.
    reject,
};

/// Which injection produced a fault. Recorded in traces and `netstat`.
pub const FaultKind = enum {
    /// Two groups cannot reach each other; other nodes reach both.
    partition,
    /// One node cannot reach, or be reached by, any other node.
    isolate,
    /// One directed link.
    cut,
    /// One directed link with extra latency and optional loss.
    degrade,
    /// A directed link disabled through `setLink`.
    link,
    /// A directed link clogged through `clog`.
    clog,
    /// A seeded automatic partition (`setPartitionDynamics`).
    auto_partition,
    /// A seeded automatic clog (`setClogs`).
    auto_clog,
};

/// Options for `partition`, `isolate`, and `cut`.
pub const FaultOptions = struct {
    mode: FaultMode = .drop,
    /// Heal automatically after this long. Must be positive and tick-aligned.
    /// Null holds the fault until it is healed explicitly.
    duration_ns: ?clock_module.Duration = null,
    /// Extra one-way latency for `.slow`. Must be tick-aligned.
    delay_ns: clock_module.Duration = 0,
};

/// Options for `degrade`: a slow, optionally lossy directed link.
pub const DegradeOptions = struct {
    /// Extra one-way latency. Must be tick-aligned.
    delay_ns: clock_module.Duration = 0,
    /// Maximum extra seeded jitter. Must be tick-aligned.
    jitter_ns: clock_module.Duration = 0,
    /// Seeded per-packet loss on top of the global loss rate.
    drop_rate: BuggifyRate = .never(),
    /// Heal automatically after this long, or null for an explicit heal.
    duration_ns: ?clock_module.Duration = null,
};

/// A handle to one active (or since healed) fault.
pub const Fault = struct {
    id: u64,
    kind: FaultKind,
    mode: FaultMode,
};

pub const Active = struct {
    id: u64,
    kind: FaultKind,
    mode: FaultMode,
    delay_ns: clock_module.Duration = 0,
    jitter_ns: clock_module.Duration = 0,
    drop_rate: BuggifyRate = .never(),
    until_ns: ?clock_module.Timestamp = null,
    /// Directed paths covered, indexed `from * nodes + to`.
    paths: std.DynamicBitSetUnmanaged,

    pub fn handle(self: *const Active) Fault {
        return .{ .id = self.id, .kind = self.kind, .mode = self.mode };
    }

    pub fn covers(self: *const Active, path: usize) bool {
        return self.paths.isSet(path);
    }

    pub fn pathCount(self: *const Active) usize {
        return self.paths.count();
    }
};

/// The combined effect of every active fault on one directed path.
pub const Verdict = struct {
    /// Set when a drop or reject fault decides the packet's fate.
    blocked: ?Blocked = null,
    /// Set when a hold fault (and no drop or reject) covers the path.
    held_by: ?u64 = null,
    /// Sum of `slow` delays of covering faults.
    delay_ns: clock_module.Duration = 0,

    pub const Blocked = struct {
        fault: u64,
        mode: FaultMode,
    };
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    nodes: usize,
    faults: std.ArrayList(Active) = .empty,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, nodes: usize) Registry {
        return .{ .allocator = allocator, .nodes = nodes };
    }

    pub fn deinit(self: *Registry) void {
        for (self.faults.items) |*fault| fault.paths.deinit(self.allocator);
        self.faults.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn pathIndex(self: *const Registry, from: NodeId, to: NodeId) usize {
        return @as(usize, from) * self.nodes + @as(usize, to);
    }

    /// Start building a fault; the caller sets covered paths and then
    /// commits it with `add`.
    pub fn emptyPaths(self: *Registry) !std.DynamicBitSetUnmanaged {
        return std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.nodes * self.nodes);
    }

    /// Add a fault that owns `paths`. On failure `paths` is freed.
    pub fn add(self: *Registry, fault: Active) !*Active {
        var owned = fault;
        errdefer owned.paths.deinit(self.allocator);
        owned.id = self.next_id;
        try self.faults.append(self.allocator, owned);
        self.next_id += 1;
        return &self.faults.items[self.faults.items.len - 1];
    }

    pub fn find(self: *Registry, id: u64) ?*Active {
        for (self.faults.items) |*fault| {
            if (fault.id == id) return fault;
        }
        return null;
    }

    /// Remove one fault. Returns false when it is not active.
    pub fn remove(self: *Registry, id: u64) bool {
        for (self.faults.items, 0..) |*fault, index| {
            if (fault.id != id) continue;
            fault.paths.deinit(self.allocator);
            _ = self.faults.orderedRemove(index);
            return true;
        }
        return false;
    }

    /// Remove every fault matching `predicate`; returns how many.
    pub fn removeWhere(self: *Registry, context: anytype, comptime predicate: fn (@TypeOf(context), *const Active) bool) usize {
        var removed: usize = 0;
        var index: usize = 0;
        while (index < self.faults.items.len) {
            const fault = &self.faults.items[index];
            if (!predicate(context, fault)) {
                index += 1;
                continue;
            }
            fault.paths.deinit(self.allocator);
            _ = self.faults.orderedRemove(index);
            removed += 1;
        }
        return removed;
    }

    pub fn clear(self: *Registry) usize {
        const count = self.faults.items.len;
        for (self.faults.items) |*fault| fault.paths.deinit(self.allocator);
        self.faults.clearRetainingCapacity();
        return count;
    }

    pub fn verdict(self: *const Registry, path: usize) Verdict {
        var result: Verdict = .{};
        var reject: ?u64 = null;
        for (self.faults.items) |*fault| {
            if (!fault.covers(path)) continue;
            switch (fault.mode) {
                .drop => if (result.blocked == null) {
                    result.blocked = .{ .fault = fault.id, .mode = .drop };
                },
                .reject => if (reject == null) {
                    reject = fault.id;
                },
                .hold => if (result.held_by == null) {
                    result.held_by = fault.id;
                },
                .slow => result.delay_ns +|= fault.delay_ns,
            }
        }
        if (result.blocked == null) {
            if (reject) |id| result.blocked = .{ .fault = id, .mode = .reject };
        }
        if (result.blocked != null) result.held_by = null;
        return result;
    }

    /// Whether any drop or reject fault covers the path.
    pub fn blocks(self: *const Registry, path: usize) bool {
        return self.verdict(path).blocked != null;
    }

    /// Whether any hold fault covers the path.
    pub fn holds(self: *const Registry, path: usize) bool {
        for (self.faults.items) |*fault| {
            if (fault.mode == .hold and fault.covers(path)) return true;
        }
        return false;
    }

    /// Latest expiry among hold faults covering the path, or null when some
    /// covering hold has no expiry or none covers it.
    pub fn holdUntil(self: *const Registry, path: usize) union(enum) { none, until: clock_module.Timestamp, indefinite } {
        var latest: ?clock_module.Timestamp = null;
        for (self.faults.items) |*fault| {
            if (fault.mode != .hold or !fault.covers(path)) continue;
            const until = fault.until_ns orelse return .indefinite;
            latest = if (latest) |value| @max(value, until) else until;
        }
        return if (latest) |value| .{ .until = value } else .none;
    }

    pub fn nextExpiryAfter(self: *const Registry, now_ns: clock_module.Timestamp, end_ns: clock_module.Timestamp) ?clock_module.Timestamp {
        var next: ?clock_module.Timestamp = null;
        for (self.faults.items) |fault| {
            const until = fault.until_ns orelse continue;
            if (until <= now_ns or until > end_ns) continue;
            next = if (next) |value| @min(value, until) else until;
        }
        return next;
    }

    /// Remove `path` from every fault; drop faults left covering nothing.
    /// Returns how many path coverages were cleared.
    pub fn clearPath(self: *Registry, path: usize) usize {
        var cleared: usize = 0;
        var index: usize = 0;
        while (index < self.faults.items.len) {
            const fault = &self.faults.items[index];
            if (fault.covers(path)) {
                fault.paths.unset(path);
                cleared += 1;
            }
            if (fault.paths.count() == 0) {
                fault.paths.deinit(self.allocator);
                _ = self.faults.orderedRemove(index);
                continue;
            }
            index += 1;
        }
        return cleared;
    }
};

test "faults: composition prefers drop, then reject, then hold, and adds slow delays" {
    var registry = Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    const path = registry.pathIndex(0, 1);

    var slow_paths = try registry.emptyPaths();
    slow_paths.set(path);
    _ = try registry.add(.{ .id = 0, .kind = .degrade, .mode = .slow, .delay_ns = 5, .paths = slow_paths });
    var slow2 = try registry.emptyPaths();
    slow2.set(path);
    _ = try registry.add(.{ .id = 0, .kind = .degrade, .mode = .slow, .delay_ns = 7, .paths = slow2 });
    try std.testing.expectEqual(@as(u64, 12), registry.verdict(path).delay_ns);

    var hold_paths = try registry.emptyPaths();
    hold_paths.set(path);
    const hold = try registry.add(.{ .id = 0, .kind = .clog, .mode = .hold, .paths = hold_paths });
    const hold_id = hold.id;
    try std.testing.expectEqual(@as(?u64, hold_id), registry.verdict(path).held_by);

    var reject_paths = try registry.emptyPaths();
    reject_paths.set(path);
    const reject_id = (try registry.add(.{ .id = 0, .kind = .cut, .mode = .reject, .paths = reject_paths })).id;
    try std.testing.expectEqual(FaultMode.reject, registry.verdict(path).blocked.?.mode);
    try std.testing.expectEqual(@as(?u64, null), registry.verdict(path).held_by);

    var drop_paths = try registry.emptyPaths();
    drop_paths.set(path);
    const drop_id = (try registry.add(.{ .id = 0, .kind = .partition, .mode = .drop, .paths = drop_paths })).id;
    try std.testing.expectEqual(drop_id, registry.verdict(path).blocked.?.fault);

    try std.testing.expect(registry.remove(drop_id));
    try std.testing.expectEqual(reject_id, registry.verdict(path).blocked.?.fault);
    try std.testing.expect(!registry.blocks(registry.pathIndex(1, 0)));
}
