//! External SUT validation for g41797/mailbox running on Marionette's
//! scheduler-backed `std.Io` futex implementation.

const std = @import("std");
const mar = @import("marionette");
const mailbox = @import("mailbox");

const Letter = u32;
const Mbx = mailbox.MailBox(Letter);

const ScenarioKind = enum {
    timeout,
    timeout_pair,
    exchange,
};

const MailboxScenario = struct {
    io: std.Io,
    mailbox: Mbx,
    envelope: Mbx.Envelope = .{ .letter = 42 },
    receivers_started: u8 = 0,
    receiver_timed_out_count: u8 = 0,
    receiver_got_letter: bool = false,
    sender_yields: u16 = 0,

    fn init(io: std.Io) MailboxScenario {
        return .{
            .io = io,
            .mailbox = .init(io),
        };
    }

    fn timeoutReceiver(_: *mar.UnstableTaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        self.receivers_started += 1;
        _ = self.mailbox.receive(30) catch |err| switch (err) {
            error.Timeout => {
                self.receiver_timed_out_count += 1;
                return;
            },
            error.Closed, error.Interrupted => @panic("unexpected mailbox receive error"),
        };
        @panic("empty mailbox receive unexpectedly succeeded");
    }

    fn exchangeReceiver(_: *mar.UnstableTaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        self.receivers_started += 1;
        const envelope = self.mailbox.receive(1000) catch |err| switch (err) {
            error.Timeout, error.Closed, error.Interrupted => @panic("unexpected mailbox receive error"),
        };
        if (envelope.letter != self.envelope.letter) @panic("unexpected mailbox letter");
        self.receiver_got_letter = true;
    }

    fn sender(scheduler: *mar.UnstableTaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        while (self.receivers_started < 1) {
            self.sender_yields += 1;
            if (self.sender_yields > 256) @panic("receiver did not start");
            scheduler.yieldCurrent();
        }
        self.mailbox.send(&self.envelope) catch @panic("mailbox send failed");
    }
};

fn runMailboxTrace(allocator: std.mem.Allocator, seed: u64, kind: ScenarioKind) ![]u8 {
    const runtime_allocator = std.heap.page_allocator;

    const world = try runtime_allocator.create(mar.World);
    errdefer runtime_allocator.destroy(world);
    world.* = try mar.World.init(runtime_allocator, .{ .seed = seed, .tick_ns = 10 });
    defer {
        world.deinit();
        runtime_allocator.destroy(world);
    }

    const scheduler = try runtime_allocator.create(mar.UnstableTaskScheduler);
    errdefer runtime_allocator.destroy(scheduler);
    scheduler.* = mar.UnstableTaskScheduler.init(runtime_allocator, world);
    defer {
        scheduler.deinit();
        runtime_allocator.destroy(scheduler);
    }

    var backend = mar.SimIo.Backend.init(runtime_allocator, world, mar.Disk.unavailable(), 4096);
    defer backend.deinit();
    backend.attachFutexWaitSet(mar.unstableTaskSchedulerFutexWaitSet(scheduler));

    const scenario = try runtime_allocator.create(MailboxScenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = MailboxScenario.init(backend.io());

    switch (kind) {
        .timeout => {
            _ = try scheduler.spawn(.{
                .entry = MailboxScenario.timeoutReceiver,
                .arg = scenario,
            });
        },
        .timeout_pair => {
            _ = try scheduler.spawn(.{
                .entry = MailboxScenario.timeoutReceiver,
                .arg = scenario,
            });
            _ = try scheduler.spawn(.{
                .entry = MailboxScenario.timeoutReceiver,
                .arg = scenario,
            });
        },
        .exchange => {
            _ = try scheduler.spawn(.{
                .entry = MailboxScenario.exchangeReceiver,
                .arg = scenario,
            });
            _ = try scheduler.spawn(.{
                .entry = MailboxScenario.sender,
                .arg = scenario,
            });
        },
    }

    try scheduler.runUntilIdle();
    try std.testing.expectEqual(@as(usize, 0), scheduler.blockedCount());

    switch (kind) {
        .timeout => {
            try std.testing.expectEqual(@as(u8, 1), scenario.receiver_timed_out_count);
            try std.testing.expectEqual(@as(u64, 30), world.now());
        },
        .timeout_pair => {
            try std.testing.expectEqual(@as(u8, 2), scenario.receiver_timed_out_count);
            try std.testing.expectEqual(@as(u64, 30), world.now());
        },
        .exchange => {
            try std.testing.expect(scenario.receiver_got_letter);
        },
    }

    return try allocator.dupe(u8, world.traceBytes());
}

test "mailbox receive timeout replays deterministically on Marionette futex timers" {
    const first = try runMailboxTrace(std.testing.allocator, 0xA11B0, .timeout);
    defer std.testing.allocator.free(first);
    const second = try runMailboxTrace(std.testing.allocator, 0xA11B0, .timeout);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.block task=0 key=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "deadline_ns=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.timeout task=0 deadline_ns=30") != null);
}

test "mailbox same-deadline receive timeouts replay in task id order" {
    const first = try runMailboxTrace(std.testing.allocator, 0xA11B2, .timeout_pair);
    defer std.testing.allocator.free(first);
    const second = try runMailboxTrace(std.testing.allocator, 0xA11B2, .timeout_pair);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    const first_timeout = std.mem.indexOf(u8, first, "scheduler.timeout task=0 deadline_ns=30").?;
    const second_timeout = std.mem.indexOf(u8, first, "scheduler.timeout task=1 deadline_ns=30").?;
    try std.testing.expect(first_timeout < second_timeout);
}

test "mailbox send wakes blocked receiver deterministically on Marionette futexes" {
    const first = try runMailboxTrace(std.testing.allocator, 0xA11B1, .exchange);
    defer std.testing.allocator.free(first);
    const second = try runMailboxTrace(std.testing.allocator, 0xA11B1, .exchange);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.block task=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "deadline_ns=1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.wake key=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.timeout") == null);
}
