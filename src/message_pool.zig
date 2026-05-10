//! Preallocated buffers for the production message bus.
//!
//! The pool is intentionally independent of sockets and framing. The future
//! bus can use it for bounded in-flight frame or payload storage.

const std = @import("std");

pub const PoolError = error{
    InvalidOptions,
    MessageTooLarge,
    PoolExhausted,
};

pub const Options = struct {
    buffers: usize,
    buffer_size: usize,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    slots: []Slot,
    free_stack: []usize,
    free_count: usize,
    buffer_size: usize,

    const Slot = struct {
        ref_count: u32 = 0,
        len: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Pool {
        if (options.buffers == 0 or options.buffer_size == 0) return error.InvalidOptions;
        const storage_len = std.math.mul(usize, options.buffers, options.buffer_size) catch {
            return error.InvalidOptions;
        };

        const storage = try allocator.alloc(u8, storage_len);
        errdefer allocator.free(storage);

        const slots = try allocator.alloc(Slot, options.buffers);
        errdefer allocator.free(slots);
        @memset(slots, .{});

        const free_stack = try allocator.alloc(usize, options.buffers);
        errdefer allocator.free(free_stack);
        for (free_stack, 0..) |*entry, index| {
            entry.* = options.buffers - 1 - index;
        }

        return .{
            .allocator = allocator,
            .storage = storage,
            .slots = slots,
            .free_stack = free_stack,
            .free_count = options.buffers,
            .buffer_size = options.buffer_size,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.allocator.free(self.free_stack);
        self.allocator.free(self.slots);
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn acquire(self: *Pool, len: usize) PoolError!Message {
        // Each message occupies one fixed-size slot, so buffer_size is this
        // pool's maximum storable message length.
        if (len > self.buffer_size) return error.MessageTooLarge;
        if (self.free_count == 0) return error.PoolExhausted;

        self.free_count -= 1;
        const index = self.free_stack[self.free_count];
        self.slots[index] = .{
            .ref_count = 1,
            .len = len,
        };

        const message: Message = .{ .pool = self, .index = index };
        @memset(message.bytes(), 0);
        return message;
    }

    pub fn freeBuffers(self: *const Pool) usize {
        return self.free_count;
    }

    pub fn liveBuffers(self: *const Pool) usize {
        return self.slots.len - self.free_count;
    }

    fn retainIndex(self: *Pool, index: usize) void {
        std.debug.assert(index < self.slots.len);
        std.debug.assert(self.slots[index].ref_count > 0);
        self.slots[index].ref_count += 1;
    }

    fn releaseIndex(self: *Pool, index: usize) void {
        std.debug.assert(index < self.slots.len);
        std.debug.assert(self.slots[index].ref_count > 0);

        self.slots[index].ref_count -= 1;
        if (self.slots[index].ref_count > 0) return;

        self.slots[index].len = 0;
        self.free_stack[self.free_count] = index;
        self.free_count += 1;
    }

    fn bytesFor(self: *Pool, index: usize) []u8 {
        std.debug.assert(index < self.slots.len);
        const start = index * self.buffer_size;
        return self.storage[start..][0..self.slots[index].len];
    }
};

pub const Message = struct {
    pool: *Pool,
    index: usize,

    pub fn bytes(self: Message) []u8 {
        return self.pool.bytesFor(self.index);
    }

    pub fn retain(self: Message) Message {
        self.pool.retainIndex(self.index);
        return self;
    }

    pub fn release(self: Message) void {
        self.pool.releaseIndex(self.index);
    }
};

test "message pool: acquire and release buffer" {
    var pool = try Pool.init(std.testing.allocator, .{ .buffers = 2, .buffer_size = 8 });
    defer pool.deinit();

    var message = try pool.acquire(4);
    defer message.release();

    try std.testing.expectEqual(@as(usize, 1), pool.liveBuffers());
    try std.testing.expectEqual(@as(usize, 1), pool.freeBuffers());

    @memcpy(message.bytes(), "ping");
    try std.testing.expectEqualStrings("ping", message.bytes());
}

test "message pool: rejects oversized message" {
    var pool = try Pool.init(std.testing.allocator, .{ .buffers = 1, .buffer_size = 4 });
    defer pool.deinit();

    try std.testing.expectError(error.MessageTooLarge, pool.acquire(5));
}

test "message pool: returns PoolExhausted when empty" {
    var pool = try Pool.init(std.testing.allocator, .{ .buffers = 1, .buffer_size = 4 });
    defer pool.deinit();

    const message = try pool.acquire(4);
    defer message.release();

    try std.testing.expectError(error.PoolExhausted, pool.acquire(1));
}

test "message pool: refcount keeps buffer live until last release" {
    var pool = try Pool.init(std.testing.allocator, .{ .buffers = 1, .buffer_size = 4 });
    defer pool.deinit();

    const first = try pool.acquire(4);
    const second = first.retain();

    first.release();
    try std.testing.expectEqual(@as(usize, 1), pool.liveBuffers());
    try std.testing.expectError(error.PoolExhausted, pool.acquire(1));

    second.release();
    try std.testing.expectEqual(@as(usize, 0), pool.liveBuffers());

    const third = try pool.acquire(1);
    third.release();
}

test "message pool: rejects invalid options" {
    try std.testing.expectError(error.InvalidOptions, Pool.init(std.testing.allocator, .{
        .buffers = 0,
        .buffer_size = 1,
    }));
    try std.testing.expectError(error.InvalidOptions, Pool.init(std.testing.allocator, .{
        .buffers = 1,
        .buffer_size = 0,
    }));
    try std.testing.expectError(error.InvalidOptions, Pool.init(std.testing.allocator, .{
        .buffers = std.math.maxInt(usize),
        .buffer_size = 2,
    }));
}
