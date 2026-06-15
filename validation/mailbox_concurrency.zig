//! External SUT validation for g41797/mailbox running on Marionette's
//! deterministic `std.Io` implementation.
//!
//! The SUT and the scenario tasks use only `std.Io`: tasks are spawned with
//! `Io.async`, and mailbox blocking goes through the simulated futex path.
//! Marionette appears only as the harness (world construction and trace
//! collection).

const std = @import("std");
const mar = @import("marionette");
const mailbox = @import("mailbox");

const Io = std.Io;
const Letter = u32;
const Mbx = mailbox.MailBox(Letter);

const ScenarioKind = enum {
    timeout,
    timeout_pair,
    exchange,
};

const MailboxScenario = struct {
    io: Io,
    mailbox: Mbx,
    envelope: Mbx.Envelope = .{ .letter = 42 },
    receiver_timed_out_count: u8 = 0,
    receiver_got_letter: bool = false,

    fn init(io: Io) MailboxScenario {
        return .{
            .io = io,
            .mailbox = .init(io),
        };
    }

    fn timeoutReceiver(self: *MailboxScenario) void {
        _ = self.mailbox.receive(30) catch |err| switch (err) {
            error.Timeout => {
                self.receiver_timed_out_count += 1;
                return;
            },
            error.Closed, error.Interrupted => @panic("unexpected mailbox receive error"),
        };
        @panic("empty mailbox receive unexpectedly succeeded");
    }

    fn exchangeReceiver(self: *MailboxScenario) void {
        const envelope = self.mailbox.receive(1000) catch |err| switch (err) {
            error.Timeout, error.Closed, error.Interrupted => @panic("unexpected mailbox receive error"),
        };
        if (envelope.letter != self.envelope.letter) @panic("unexpected mailbox letter");
        self.receiver_got_letter = true;
    }

    fn sender(self: *MailboxScenario) void {
        // Sleep one tick before sending: simulated time only advances once
        // every non-timed task has parked, so the receiver is guaranteed to
        // be blocked in `receive` and the send exercises the futex wake of
        // a blocked waiter rather than a fast-path receive.
        Io.sleep(self.io, .fromNanoseconds(10), .awake) catch unreachable;
        self.mailbox.send(&self.envelope) catch @panic("mailbox send failed");
    }
};

fn runMailboxTrace(allocator: std.mem.Allocator, seed: u64, kind: ScenarioKind) ![]u8 {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var scenario = MailboxScenario.init(io);

    switch (kind) {
        .timeout => {
            var receiver = Io.async(io, MailboxScenario.timeoutReceiver, .{&scenario});
            receiver.await(io);
            try std.testing.expectEqual(@as(u8, 1), scenario.receiver_timed_out_count);
            try std.testing.expectEqual(@as(u64, 30), world.now());
        },
        .timeout_pair => {
            var first = Io.async(io, MailboxScenario.timeoutReceiver, .{&scenario});
            var second = Io.async(io, MailboxScenario.timeoutReceiver, .{&scenario});
            first.await(io);
            second.await(io);
            try std.testing.expectEqual(@as(u8, 2), scenario.receiver_timed_out_count);
            try std.testing.expectEqual(@as(u64, 30), world.now());
        },
        .exchange => {
            var receiver = Io.async(io, MailboxScenario.exchangeReceiver, .{&scenario});
            var send = Io.async(io, MailboxScenario.sender, .{&scenario});
            receiver.await(io);
            send.await(io);
            try std.testing.expect(scenario.receiver_got_letter);
        },
    }

    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
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
    // The sender's own one-tick sleep times out by design; the receiver
    // (task 0) must be woken by the send, never by its 1000ns deadline.
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.timeout task=0") == null);
}
