//! External SUT validation for g41797/mailbox running on Marionette's
//! deterministic `std.Io` implementation.
//!
//! The SUT and the scenario tasks use only `std.Io`: tasks are spawned with
//! `Io.async`, and mailbox blocking goes through the simulated futex path.
//! Marionette appears only as the harness: a `mar.Harness` per scenario,
//! whose runner executes each seed twice and compares the traces.

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
    control: mar.Control,
    io: Io,
    mailbox: Mbx,
    envelope: Mbx.Envelope = .{ .letter = 42 },
    receiver_timed_out_count: u8 = 0,
    receiver_got_letter: bool = false,

    fn init(control: mar.Control, io: Io) MailboxScenario {
        return .{
            .control = control,
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
            error.Closed, error.Interrupted => |other| return self.control.failRun(other),
        };
        self.control.failRun(error.EmptyReceiveSucceeded);
    }

    fn exchangeReceiver(self: *MailboxScenario) void {
        const envelope = self.mailbox.receive(1000) catch |err| switch (err) {
            error.Timeout, error.Closed, error.Interrupted => |other| return self.control.failRun(other),
        };
        if (envelope.letter != self.envelope.letter) return self.control.failRun(error.UnexpectedLetter);
        self.receiver_got_letter = true;
    }

    fn sender(self: *MailboxScenario) void {
        // Sleep one tick before sending: simulated time only advances once
        // every non-timed task has parked, so the receiver is guaranteed to
        // be blocked in `receive` and the send exercises the futex wake of
        // a blocked waiter rather than a fast-path receive.
        Io.sleep(self.io, .fromNanoseconds(10), .awake) catch return;
        self.mailbox.send(&self.envelope) catch |err| return self.control.failRun(err);
    }
};

fn App(comptime kind: ScenarioKind) type {
    return struct {
        scenario: MailboxScenario,

        fn init(sim: mar.Sim) @This() {
            return .{ .scenario = .init(sim.control, sim.env.io()) };
        }

        fn run(case: *mar.SimCase(@This())) !void {
            const scenario = &case.app.scenario;
            const io = scenario.io;
            switch (kind) {
                .timeout => {
                    var receiver = Io.async(io, MailboxScenario.timeoutReceiver, .{scenario});
                    receiver.await(io);
                    try std.testing.expectEqual(@as(u8, 1), scenario.receiver_timed_out_count);
                    try std.testing.expectEqual(@as(u64, 30), case.control().now());
                },
                .timeout_pair => {
                    var first = Io.async(io, MailboxScenario.timeoutReceiver, .{scenario});
                    var second = Io.async(io, MailboxScenario.timeoutReceiver, .{scenario});
                    first.await(io);
                    second.await(io);
                    try std.testing.expectEqual(@as(u8, 2), scenario.receiver_timed_out_count);
                    try std.testing.expectEqual(@as(u64, 30), case.control().now());
                },
                .exchange => {
                    var receiver = Io.async(io, MailboxScenario.exchangeReceiver, .{scenario});
                    var send = Io.async(io, MailboxScenario.sender, .{scenario});
                    receiver.await(io);
                    send.await(io);
                    try std.testing.expect(scenario.receiver_got_letter);
                },
            }
            if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;
        }
    };
}

/// Run one scenario through its harness and return the verified trace.
fn runMailboxTrace(allocator: std.mem.Allocator, seed: u64, comptime kind: ScenarioKind) ![]u8 {
    const H = mar.Harness(.{ .init = App(kind).init, .scenario = App(kind).run, .name = "mailbox." ++ @tagName(kind) });
    var report = try H.run(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer report.deinit();
    switch (report) {
        .passed => |passed| return allocator.dupe(u8, passed.trace),
        .failed => |failure| {
            failure.print();
            return error.ScenarioFailed;
        },
    }
}

test "mailbox receive timeout replays deterministically on Marionette futex timers" {
    const first = try runMailboxTrace(std.testing.allocator, 0xA11B0, .timeout);
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.block task=0 key=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "deadline_ns=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.timeout task=0 deadline_ns=30") != null);
}

test "mailbox same-deadline receive timeouts replay in task id order" {
    const first = try runMailboxTrace(std.testing.allocator, 0xA11B2, .timeout_pair);
    defer std.testing.allocator.free(first);
    const first_timeout = std.mem.indexOf(u8, first, "scheduler.timeout task=0 deadline_ns=30").?;
    const second_timeout = std.mem.indexOf(u8, first, "scheduler.timeout task=1 deadline_ns=30").?;
    try std.testing.expect(first_timeout < second_timeout);
}

test "mailbox send wakes blocked receiver deterministically on Marionette futexes" {
    const first = try runMailboxTrace(std.testing.allocator, 0xA11B1, .exchange);
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.block task=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "deadline_ns=1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.wake key=") != null);
    // The sender's own one-tick sleep times out by design; the receiver
    // (task 0) must be woken by the send, never by its 1000ns deadline.
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.timeout task=0") == null);
}
