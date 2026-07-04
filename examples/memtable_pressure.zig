//! Memtable allocation-pressure example.
//!
//! Allocation failure is a modeled branch, not an abort: a put that cannot
//! allocate must be rejected without mutating table state. The planted bug
//! counts an insert as committed before allocating its value copy, so a
//! deterministic OOM leaves a phantom commit that the checker catches.

const std = @import("std");
const mar = @import("marionette");

const value_buffer_len = 16;
const buggify_put_count: u32 = 8;

const Case = mar.SimCase(Memtable);

pub const checks = [_]mar.StateCheck(Case){
    .{ .name = "committed puts match stored entries", .check = commitIntegrity },
};

/// Run the correct allocation-pressure scenario and return an owned trace.
pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var report = try runScenarioReport(allocator, seed);
    defer report.deinit();

    switch (report) {
        .passed => |*passed| return passed.takeTrace(),
        .failed => |failure| {
            failure.print();
            return error.MemtableScenarioFailed;
        },
    }
}

pub fn runScenarioReport(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return mar.runSimCase(.{
        .allocator = allocator,
        .seed = seed,
        .name = "memtable-allocation-pressure",
        .simulate = .{},
        .init = Memtable.init,
        .scenario = scenario,
        .checks = &checks,
    });
}

/// Run the planted commit-before-allocate bug under the same fault choreography.
pub fn runBuggyScenarioReport(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return mar.runSimCase(.{
        .allocator = allocator,
        .seed = seed,
        .name = "memtable-phantom-commit",
        .simulate = .{},
        .init = Memtable.init,
        .scenario = buggyScenario,
        .checks = &checks,
    });
}

pub fn runBuggifyScenarioReport(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return mar.runSimCase(.{
        .allocator = allocator,
        .seed = seed,
        .name = "memtable-allocation-buggify",
        .simulate = .{},
        .init = Memtable.init,
        .scenario = buggifyScenario,
        .checks = &checks,
    });
}

fn scenario(case: *Case) !void {
    try runPressureScenario(case, .strict);
}

fn buggyScenario(case: *Case) !void {
    try runPressureScenario(case, .buggy_commit_before_alloc);
}

fn runPressureScenario(case: *Case, mode: PutMode) !void {
    const table = &case.app;
    var buffer: [value_buffer_len]u8 = undefined;

    try table.put(1, valueFor(1, &buffer), mode);

    // Every allocation and growth request from here on fails deterministically.
    try case.control().allocation.setFaults(.{ .fail_after = 0 });
    table.put(2, valueFor(2, &buffer), mode) catch |err| switch (err) {
        error.OutOfMemory => {},
        else => return err,
    };

    try case.control().allocation.setFaults(.{});
    try table.put(3, valueFor(3, &buffer), mode);
}

fn buggifyScenario(case: *Case) !void {
    const table = &case.app;
    var buffer: [value_buffer_len]u8 = undefined;

    try case.control().allocation.setFaults(.{ .buggify_rate = .percent(25) });

    var key: u32 = 1;
    while (key <= buggify_put_count) : (key += 1) {
        table.put(key, valueFor(key, &buffer), .strict) catch |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        };
    }

    try case.control().allocation.setFaults(.{});
}

fn commitIntegrity(case: *const Case) !void {
    const table = &case.app;

    if (table.committed_count != table.entries.items.len) {
        try table.env.record(
            "memtable.invariant_violation reason=phantom_commit committed={} entries={}",
            .{ table.committed_count, table.entries.items.len },
        );
        return error.PhantomCommit;
    }

    var buffer: [value_buffer_len]u8 = undefined;
    for (table.entries.items, 0..) |entry, index| {
        for (table.entries.items[0..index]) |earlier| {
            if (earlier.key == entry.key) {
                try table.env.record(
                    "memtable.invariant_violation reason=duplicate_key key={}",
                    .{entry.key},
                );
                return error.DuplicateKey;
            }
        }
        if (!std.mem.eql(u8, entry.value, valueFor(entry.key, &buffer))) {
            try table.env.record(
                "memtable.invariant_violation reason=corrupt_entry key={}",
                .{entry.key},
            );
            return error.CorruptEntry;
        }
    }

    try table.env.record(
        "memtable.check commit_integrity=ok committed={} rejected={}",
        .{ table.committed_count, table.rejected_count },
    );
}

fn valueFor(key: u32, buffer: *[value_buffer_len]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "value-{}", .{key}) catch unreachable;
}

const PutMode = enum {
    strict,
    buggy_commit_before_alloc,
};

const Entry = struct {
    key: u32,
    value: []u8,
};

const Memtable = struct {
    env: mar.Env,
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    committed_count: usize = 0,
    rejected_count: usize = 0,

    fn init(sim: mar.Sim) Memtable {
        return .{
            .env = sim.env,
            .allocator = sim.env.allocator(),
        };
    }

    pub fn deinit(self: *Memtable) void {
        for (self.entries.items) |entry| self.allocator.free(entry.value);
        self.entries.deinit(self.allocator);
    }

    fn put(self: *Memtable, key: u32, value: []const u8, mode: PutMode) !void {
        // The planted bug: the commit is counted before the allocations that
        // back it have succeeded.
        if (mode == .buggy_commit_before_alloc) self.committed_count += 1;

        const copy = self.allocator.dupe(u8, value) catch |err| {
            try self.recordRejected(key);
            return err;
        };
        self.entries.append(self.allocator, .{ .key = key, .value = copy }) catch |err| {
            self.allocator.free(copy);
            try self.recordRejected(key);
            return err;
        };

        if (mode == .strict) self.committed_count += 1;
        try self.env.record(
            "memtable.put key={} accepted=true committed={}",
            .{ key, self.committed_count },
        );
    }

    fn recordRejected(self: *Memtable, key: u32) !void {
        self.rejected_count += 1;
        try self.env.record(
            "memtable.put key={} accepted=false reason=allocation_rejected committed={}",
            .{ key, self.committed_count },
        );
    }
};

test "memtable: allocation rejection passes through expectation helper" {
    try mar.expectSimPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .simulate = .{},
        .init = Memtable.init,
        .scenario = scenario,
        .checks = &checks,
    });
}

test "memtable: phantom commit fails through expectation helper" {
    try mar.expectSimFailure(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .simulate = .{},
        .init = Memtable.init,
        .scenario = buggyScenario,
        .checks = &checks,
    });
}

test "memtable: probabilistic allocation faults fuzz clean" {
    try mar.expectSimFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .seeds = 16,
        .simulate = .{},
        .init = Memtable.init,
        .scenario = buggifyScenario,
        .checks = &checks,
    });
}
