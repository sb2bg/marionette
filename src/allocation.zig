//! App-facing allocation authority for production and simulation.
//!
//! Simulation wraps a caller-provided backing allocator with deterministic
//! faults and address-free tracing. World internals continue to allocate from
//! the harness allocator so modeled app OOMs do not corrupt simulator state.

const std = @import("std");

const fault_module = @import("fault.zig");

pub const BuggifyRate = fault_module.BuggifyRate;
pub const BuggifyError = fault_module.BuggifyError;

/// Runtime allocation-fault configuration.
pub const FaultOptions = struct {
    /// Number of successful allocation/growth requests allowed before
    /// subsequent allocation/growth requests fail.
    fail_after: ?usize = null,
    /// Maximum modeled app bytes live at once.
    quota_bytes: ?usize = null,
    /// Seeded probabilistic allocation/growth failure rate.
    buggify_rate: BuggifyRate = .never(),

    /// Validate the buggify rate (`error.InvalidRate` otherwise).
    pub fn validate(self: FaultOptions) BuggifyError!void {
        try self.buggify_rate.validate();
    }
};

/// Address-free counters exposed to harnesses.
pub const Stats = struct {
    operation_index: u64,
    successful_allocations: usize,
    live_bytes: usize,
    total_allocated_bytes: usize,
    total_freed_bytes: usize,
};

/// Infallible-by-contract trace sink used from allocator vtable callbacks.
///
/// The callback may still fail due to harness allocation failure while growing
/// the trace log; allocation callbacks treat that as a failed app allocation
/// where they still can, and otherwise leave the app allocation result intact.
pub const TraceSink = struct {
    ptr: *anyopaque,
    record: *const fn (*anyopaque, []const u8) anyerror!void,
};

/// Seeded random source for allocation BUGGIFY decisions.
pub const RandomSource = struct {
    ptr: *anyopaque,
    int_less_than: *const fn (*anyopaque, u32) anyerror!u32,
};

/// Deterministic allocation authority wrapped around a backing allocator.
/// Simulation builds one per world; `allocator()` is what apps receive from
/// `Env.allocator()` and `control()` is the harness fault handle.
pub const Authority = struct {
    backing: std.mem.Allocator,
    faults: FaultOptions,
    trace: ?TraceSink,
    random: ?RandomSource,
    operation_index: u64 = 0,
    successful_allocations: usize = 0,
    live_bytes: usize = 0,
    total_allocated_bytes: usize = 0,
    total_freed_bytes: usize = 0,

    /// Initial faults plus the trace and random hookups simulation wires
    /// to the world.
    pub const Options = struct {
        faults: FaultOptions = .{},
        trace: ?TraceSink = null,
        random: ?RandomSource = null,
    };

    /// Wrap `backing` with deterministic fault injection and tracing.
    pub fn init(backing: std.mem.Allocator, options: Options) Authority {
        return .{
            .backing = backing,
            .faults = options.faults,
            .trace = options.trace,
            .random = options.random,
        };
    }

    /// The app-facing allocator. Injected failures surface as ordinary
    /// `error.OutOfMemory`; decisions are traced without addresses.
    pub fn allocator(self: *Authority) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &allocator_vtable,
        };
    }

    /// The harness-facing fault and stats handle.
    pub fn control(self: *Authority) Control {
        return .{ .authority = self };
    }

    fn stats(self: *const Authority) Stats {
        return .{
            .operation_index = self.operation_index,
            .successful_allocations = self.successful_allocations,
            .live_bytes = self.live_bytes,
            .total_allocated_bytes = self.total_allocated_bytes,
            .total_freed_bytes = self.total_freed_bytes,
        };
    }

    fn setFaults(self: *Authority, faults: FaultOptions) BuggifyError!void {
        try faults.validate();
        self.faults = faults;
    }
};

/// Simulator-control view over allocation faults, obtained as
/// `sim.control.allocation`.
pub const Control = struct {
    authority: *Authority,

    /// Replace allocation fault configuration for subsequent app allocations.
    pub fn setFaults(self: Control, faults: FaultOptions) BuggifyError!void {
        try self.authority.setFaults(faults);
    }

    /// Return current address-free allocation counters.
    pub fn stats(self: Control) Stats {
        return self.authority.stats();
    }
};

const allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

const GrowthDecision = union(enum) {
    allow: struct { roll: ?u32 = null },
    fail: struct { reason: []const u8, roll: ?u32 = null },
};

fn authority(ptr: *anyopaque) *Authority {
    return @ptrCast(@alignCast(ptr));
}

fn alloc(
    ctx: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) ?[*]u8 {
    const self = authority(ctx);
    const op = nextOperation(self);

    const decision = decideGrowth(self, len);
    switch (decision) {
        .allow => |allowed| {
            const memory = self.backing.rawAlloc(len, alignment, ret_addr) orelse {
                _ = recordAlloc(self, op, len, alignment, "fail", "backing_oom", allowed.roll);
                return null;
            };

            noteGrowthSuccess(self, len);

            if (!recordAlloc(self, op, len, alignment, "ok", "none", allowed.roll)) {
                rollbackGrowthSuccess(self, len);
                self.backing.rawFree(memory[0..len], alignment, ret_addr);
                return null;
            }
            return memory;
        },
        .fail => |failed| {
            _ = recordAlloc(self, op, len, alignment, "fail", failed.reason, failed.roll);
            return null;
        },
    }
}

fn resize(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    const self = authority(ctx);
    const op = nextOperation(self);

    if (new_len <= memory.len) {
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) {
            _ = recordResize(self, op, memory.len, new_len, alignment, "fail", "backing_unsupported", null);
            return false;
        }
        noteShrink(self, memory.len - new_len);
        _ = recordResize(self, op, memory.len, new_len, alignment, "ok", "none", null);
        return true;
    }

    const growth = new_len - memory.len;
    const decision = decideGrowth(self, growth);
    switch (decision) {
        .allow => |allowed| {
            if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) {
                _ = recordResize(self, op, memory.len, new_len, alignment, "fail", "backing_unsupported", allowed.roll);
                return false;
            }
            noteGrowthSuccess(self, growth);
            _ = recordResize(self, op, memory.len, new_len, alignment, "ok", "none", allowed.roll);
            return true;
        },
        .fail => |failed| {
            _ = recordResize(self, op, memory.len, new_len, alignment, "fail", failed.reason, failed.roll);
            return false;
        },
    }
}

fn remap(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    const self = authority(ctx);
    const op = nextOperation(self);

    if (new_len <= memory.len) {
        if (self.backing.rawRemap(memory, alignment, new_len, ret_addr)) |new_ptr| {
            noteShrink(self, memory.len - new_len);
            _ = recordRemap(self, op, memory.len, new_len, alignment, "ok", "none", null);
            return new_ptr;
        }
        if (self.backing.rawResize(memory, alignment, new_len, ret_addr)) {
            noteShrink(self, memory.len - new_len);
            _ = recordRemap(self, op, memory.len, new_len, alignment, "ok", "none", null);
            return memory.ptr;
        }
        _ = recordRemap(self, op, memory.len, new_len, alignment, "fail", "backing_unsupported", null);
        return null;
    }

    const growth = new_len - memory.len;
    const decision = decideGrowth(self, growth);
    switch (decision) {
        .allow => |allowed| {
            if (self.backing.rawRemap(memory, alignment, new_len, ret_addr)) |new_ptr| {
                noteGrowthSuccess(self, growth);
                _ = recordRemap(self, op, memory.len, new_len, alignment, "ok", "none", allowed.roll);
                return new_ptr;
            }

            const new_ptr = self.backing.rawAlloc(new_len, alignment, ret_addr) orelse {
                _ = recordRemap(self, op, memory.len, new_len, alignment, "fail", "backing_oom", allowed.roll);
                return null;
            };
            @memcpy(new_ptr[0..memory.len], memory);

            noteGrowthSuccess(self, growth);
            if (!recordRemap(self, op, memory.len, new_len, alignment, "ok", "none", allowed.roll)) {
                rollbackGrowthSuccess(self, growth);
                self.backing.rawFree(new_ptr[0..new_len], alignment, ret_addr);
                return null;
            }

            self.backing.rawFree(memory, alignment, ret_addr);
            return new_ptr;
        },
        .fail => |failed| {
            _ = recordRemap(self, op, memory.len, new_len, alignment, "fail", failed.reason, failed.roll);
            return null;
        },
    }
}

fn free(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) void {
    const self = authority(ctx);
    const op = nextOperation(self);

    noteFree(self, memory.len);
    _ = recordFree(self, op, memory.len, alignment);
    self.backing.rawFree(memory, alignment, ret_addr);
}

fn nextOperation(self: *Authority) u64 {
    const op = self.operation_index;
    self.operation_index += 1;
    return op;
}

fn decideGrowth(self: *Authority, len: usize) GrowthDecision {
    if (self.faults.fail_after) |fail_after| {
        if (self.successful_allocations >= fail_after) {
            return .{ .fail = .{ .reason = "fail_after" } };
        }
    }

    if (self.faults.quota_bytes) |quota| {
        if (self.live_bytes > quota or len > quota - self.live_bytes) {
            return .{ .fail = .{ .reason = "quota" } };
        }
    } else if (std.math.maxInt(usize) - self.live_bytes < len) {
        return .{ .fail = .{ .reason = "overflow" } };
    }
    if (std.math.maxInt(usize) - self.total_allocated_bytes < len or
        self.successful_allocations == std.math.maxInt(usize))
    {
        return .{ .fail = .{ .reason = "overflow" } };
    }

    const rate = self.faults.buggify_rate;
    if (rate.numerator == 0) return .{ .allow = .{} };

    const random = self.random orelse return .{ .fail = .{ .reason = "missing_random" } };
    const roll = random.int_less_than(random.ptr, rate.denominator) catch {
        return .{ .fail = .{ .reason = "random_error" } };
    };
    if (roll < rate.numerator) {
        return .{ .fail = .{ .reason = "buggify", .roll = roll } };
    }
    return .{ .allow = .{ .roll = roll } };
}

fn noteGrowthSuccess(self: *Authority, len: usize) void {
    self.live_bytes += len;
    self.total_allocated_bytes += len;
    self.successful_allocations += 1;
}

fn rollbackGrowthSuccess(self: *Authority, len: usize) void {
    self.live_bytes -= len;
    self.total_allocated_bytes -= len;
    self.successful_allocations -= 1;
}

fn noteShrink(self: *Authority, len: usize) void {
    std.debug.assert(self.live_bytes >= len);
    self.live_bytes -= len;
    noteFreedBytes(self, len);
}

fn noteFree(self: *Authority, len: usize) void {
    std.debug.assert(self.live_bytes >= len);
    self.live_bytes -= len;
    noteFreedBytes(self, len);
}

fn noteFreedBytes(self: *Authority, len: usize) void {
    self.total_freed_bytes = std.math.add(usize, self.total_freed_bytes, len) catch std.math.maxInt(usize);
}

fn recordAlloc(
    self: *Authority,
    op: u64,
    len: usize,
    alignment: std.mem.Alignment,
    status: []const u8,
    reason: []const u8,
    roll: ?u32,
) bool {
    if (roll) |value| {
        return record(
            self,
            "allocation.alloc op={} len={} align={} status={s} reason={s} roll={} live_bytes={} successful_allocations={}",
            .{ op, len, alignment.toByteUnits(), status, reason, value, self.live_bytes, self.successful_allocations },
        );
    }
    return record(
        self,
        "allocation.alloc op={} len={} align={} status={s} reason={s} roll=none live_bytes={} successful_allocations={}",
        .{ op, len, alignment.toByteUnits(), status, reason, self.live_bytes, self.successful_allocations },
    );
}

fn recordResize(
    self: *Authority,
    op: u64,
    old_len: usize,
    new_len: usize,
    alignment: std.mem.Alignment,
    status: []const u8,
    reason: []const u8,
    roll: ?u32,
) bool {
    if (roll) |value| {
        return record(
            self,
            "allocation.resize op={} old_len={} new_len={} align={} status={s} reason={s} roll={} live_bytes={} successful_allocations={}",
            .{ op, old_len, new_len, alignment.toByteUnits(), status, reason, value, self.live_bytes, self.successful_allocations },
        );
    }
    return record(
        self,
        "allocation.resize op={} old_len={} new_len={} align={} status={s} reason={s} roll=none live_bytes={} successful_allocations={}",
        .{ op, old_len, new_len, alignment.toByteUnits(), status, reason, self.live_bytes, self.successful_allocations },
    );
}

fn recordRemap(
    self: *Authority,
    op: u64,
    old_len: usize,
    new_len: usize,
    alignment: std.mem.Alignment,
    status: []const u8,
    reason: []const u8,
    roll: ?u32,
) bool {
    if (roll) |value| {
        return record(
            self,
            "allocation.remap op={} old_len={} new_len={} align={} status={s} reason={s} roll={} live_bytes={} successful_allocations={}",
            .{ op, old_len, new_len, alignment.toByteUnits(), status, reason, value, self.live_bytes, self.successful_allocations },
        );
    }
    return record(
        self,
        "allocation.remap op={} old_len={} new_len={} align={} status={s} reason={s} roll=none live_bytes={} successful_allocations={}",
        .{ op, old_len, new_len, alignment.toByteUnits(), status, reason, self.live_bytes, self.successful_allocations },
    );
}

fn recordFree(
    self: *Authority,
    op: u64,
    len: usize,
    alignment: std.mem.Alignment,
) bool {
    return record(
        self,
        "allocation.free op={} len={} align={} live_bytes={} successful_allocations={}",
        .{ op, len, alignment.toByteUnits(), self.live_bytes, self.successful_allocations },
    );
}

fn record(self: *Authority, comptime fmt: []const u8, args: anytype) bool {
    const trace = self.trace orelse return true;
    var buffer: [512]u8 = undefined;
    const payload = std.fmt.bufPrint(&buffer, fmt, args) catch return false;
    trace.record(trace.ptr, payload) catch return false;
    return true;
}

test "allocation: fail-after faults are traced without addresses" {
    var trace_log: std.ArrayList(u8) = .empty;
    defer trace_log.deinit(std.testing.allocator);

    var trace = TestTrace{ .log = &trace_log };
    var authority_state = Authority.init(std.testing.allocator, .{
        .faults = .{ .fail_after = 1 },
        .trace = trace.sink(),
    });
    const allocator = authority_state.allocator();

    const first = try allocator.alloc(u8, 4);
    defer allocator.free(first);

    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 4));
    try std.testing.expect(std.mem.indexOf(u8, trace_log.items, "allocation.alloc op=0 len=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace_log.items, "status=fail reason=fail_after") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace_log.items, "0x") == null);
}

test "allocation: quota tracks live bytes" {
    var authority_state = Authority.init(std.testing.allocator, .{
        .faults = .{ .quota_bytes = 4 },
    });
    const allocator = authority_state.allocator();

    const first = try allocator.alloc(u8, 4);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    allocator.free(first);

    const second = try allocator.alloc(u8, 4);
    allocator.free(second);

    const stats_snapshot = authority_state.control().stats();
    try std.testing.expectEqual(@as(usize, 0), stats_snapshot.live_bytes);
    try std.testing.expectEqual(@as(usize, 2), stats_snapshot.successful_allocations);
}

const TestTrace = struct {
    log: *std.ArrayList(u8),

    fn sink(self: *TestTrace) TraceSink {
        return .{ .ptr = self, .record = recordTrace };
    }

    fn recordTrace(ptr: *anyopaque, payload: []const u8) !void {
        const self: *TestTrace = @ptrCast(@alignCast(ptr));
        try self.log.appendSlice(std.testing.allocator, payload);
        try self.log.append(std.testing.allocator, '\n');
    }
};
