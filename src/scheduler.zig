//! Deterministic scheduler building blocks.

const std = @import("std");

/// Errors returned by fixed-capacity event queues.
pub const EventQueueError = error{
    EventQueueFull,
};

/// Fixed-capacity deterministic event queue.
///
/// This is not the final Marionette scheduler. It is a small shared primitive
/// for examples and early designs that need stable event ordering.
/// `pop` does a linear scan, which is fine for Phase 0. Replace this with a
/// heap once the scheduler becomes hot or user-facing.
pub fn EventQueue(
    comptime Event: type,
    comptime capacity: usize,
    comptime lessThan: fn (Event, Event) bool,
) type {
    return struct {
        const Self = @This();

        items: [capacity]Event = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn push(self: *Self, event: Event) EventQueueError!void {
            if (self.len == self.items.len) return error.EventQueueFull;
            self.items[self.len] = event;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?Event {
            if (self.len == 0) return null;

            const index = self.nextIndex();
            const event = self.items[index];
            std.mem.copyForwards(
                Event,
                self.items[index .. self.len - 1],
                self.items[index + 1 .. self.len],
            );
            self.len -= 1;
            return event;
        }

        fn nextIndex(self: *const Self) usize {
            std.debug.assert(self.len > 0);

            var best: usize = 0;
            for (self.items[1..self.len], 1..) |event, index| {
                if (lessThan(event, self.items[best])) {
                    best = index;
                }
            }
            return best;
        }
    };
}

const TestEvent = struct {
    ready_at: u64,
    id: u64,
};

fn testEventLessThan(a: TestEvent, b: TestEvent) bool {
    return a.ready_at < b.ready_at or (a.ready_at == b.ready_at and a.id < b.id);
}

test "EventQueue: pops events in deterministic order" {
    const Queue = EventQueue(TestEvent, 4, testEventLessThan);
    var queue = Queue.init();

    try queue.push(.{ .ready_at = 20, .id = 2 });
    try queue.push(.{ .ready_at = 10, .id = 3 });
    try queue.push(.{ .ready_at = 10, .id = 1 });

    try std.testing.expectEqual(@as(usize, 3), queue.count());
    try std.testing.expectEqual(TestEvent{ .ready_at = 10, .id = 1 }, queue.pop().?);
    try std.testing.expectEqual(TestEvent{ .ready_at = 10, .id = 3 }, queue.pop().?);
    try std.testing.expectEqual(TestEvent{ .ready_at = 20, .id = 2 }, queue.pop().?);
    try std.testing.expectEqual(@as(?TestEvent, null), queue.pop());
}

test "EventQueue: reports capacity overflow" {
    const Queue = EventQueue(TestEvent, 1, testEventLessThan);
    var queue = Queue.init();

    try queue.push(.{ .ready_at = 1, .id = 1 });
    try std.testing.expectError(
        EventQueueError.EventQueueFull,
        queue.push(.{ .ready_at = 2, .id = 2 }),
    );
}
