//! Deterministic `std.Io` backend coordinator for simulation worlds.
//!
//! This module owns shared handle state and the `std.Io.VTable`. File, network,
//! futex, and error-translation behavior lives in focused sibling modules.
//! Unsupported filesystem, process, and concurrency operations fail closed.

const std = @import("std");

const disk_module = @import("../disk/root.zig");
const file_module = @import("file.zig");
const futex_module = @import("futex.zig");
const net_module = @import("net.zig");
const network_module = @import("../network/root.zig");
const World = @import("../world.zig").World;
const traceField = @import("../world.zig").traceField;

const Io = std.Io;
const SocketHandle = Io.net.Socket.Handle;

const FileLockRegistry = struct {
    allocator: std.mem.Allocator,
    locks: std.ArrayList(LockState) = .empty,
    next_key: usize = 1,

    const LockState = struct {
        path: []u8,
        key: usize,
        shared: usize = 0,
        exclusive: bool = false,
        reservations: usize = 0,
        waiters: std.ArrayList(*Waiter) = .empty,

        fn deinit(self: *LockState, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            for (self.waiters.items) |waiter| allocator.destroy(waiter);
            self.waiters.deinit(allocator);
            self.* = undefined;
        }
    };

    const Waiter = struct {
        owner: *anyopaque,
        task_owned: bool,
        ready: bool = false,
    };

    fn init(allocator: std.mem.Allocator) FileLockRegistry {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FileLockRegistry) void {
        for (self.locks.items) |*lock| lock.deinit(self.allocator);
        self.locks.deinit(self.allocator);
        self.* = undefined;
    }

    fn find(self: *FileLockRegistry, path: []const u8) ?*LockState {
        const index = self.findIndex(path) orelse return null;
        return &self.locks.items[index];
    }

    fn findIndex(self: *FileLockRegistry, path: []const u8) ?usize {
        for (self.locks.items, 0..) |*lock, index| {
            if (std.mem.eql(u8, lock.path, path)) {
                return index;
            }
        }
        return null;
    }

    fn getOrCreate(self: *FileLockRegistry, path: []const u8) std.mem.Allocator.Error!*LockState {
        if (self.find(path)) |lock| return lock;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const key = self.next_key;
        self.next_key += 1;
        try self.locks.append(self.allocator, .{
            .path = owned_path,
            .key = key,
        });
        return &self.locks.items[self.locks.items.len - 1];
    }

    fn acquire(
        self: *FileLockRegistry,
        owner: *anyopaque,
        runtime: ?TaskRuntime,
        path: []const u8,
        lock_mode: Io.File.Lock,
        nonblocking: bool,
    ) (std.mem.Allocator.Error || error{WouldBlock})!void {
        if (lock_mode == .none) return;

        while (true) {
            const lock = try self.getOrCreate(path);
            const available = switch (lock_mode) {
                .none => true,
                .shared => lock.reservations == 0 and !lock.exclusive,
                .exclusive => lock.reservations == 0 and !lock.exclusive and lock.shared == 0,
            };
            if (available) {
                switch (lock_mode) {
                    .none => {},
                    .shared => lock.shared += 1,
                    .exclusive => lock.exclusive = true,
                }
                return;
            }
            if (nonblocking) return error.WouldBlock;

            const task_runtime = runtime orelse return error.WouldBlock;
            const in_task = task_runtime.inTask();
            const waiter = try self.allocator.create(Waiter);
            errdefer self.allocator.destroy(waiter);
            waiter.* = .{
                .owner = owner,
                .task_owned = in_task,
            };
            try lock.waiters.append(self.allocator, waiter);
            const key = lock.key;
            if (in_task) {
                task_runtime.block(futex_module.waitKey(.file_lock, key));
            } else {
                task_runtime.runUntilDone(&waiter.ready);
            }
            self.removeWaiter(waiter);
        }
    }

    fn release(
        self: *FileLockRegistry,
        runtime: ?TaskRuntime,
        path: []const u8,
        lock_mode: Io.File.Lock,
    ) void {
        if (lock_mode == .none) return;
        const lock = self.find(path) orelse unreachable;
        switch (lock_mode) {
            .none => {},
            .shared => {
                std.debug.assert(lock.shared > 0);
                lock.shared -= 1;
            },
            .exclusive => {
                std.debug.assert(lock.exclusive);
                lock.exclusive = false;
            },
        }
        for (lock.waiters.items) |waiter| waiter.ready = true;
        const key = lock.key;
        const empty = lock.shared == 0 and !lock.exclusive and lock.reservations == 0 and lock.waiters.items.len == 0;
        if (runtime) |task_runtime| {
            _ = task_runtime.wake(
                futex_module.waitKey(.file_lock, key),
                std.math.maxInt(usize),
            );
        }
        if (empty) {
            const index = self.findIndex(path) orelse unreachable;
            var removed = self.locks.orderedRemove(index);
            removed.deinit(self.allocator);
        }
    }

    fn rekey(
        self: *FileLockRegistry,
        runtime: ?TaskRuntime,
        old_path: []const u8,
        new_path: []u8,
    ) void {
        const lock_index = self.findIndex(old_path) orelse {
            self.allocator.free(new_path);
            return;
        };
        if (self.findIndex(new_path)) |existing_index| {
            if (existing_index != lock_index) {
                const existing = &self.locks.items[existing_index];
                std.debug.assert(existing.shared == 0);
                std.debug.assert(!existing.exclusive);
                std.debug.assert(existing.reservations == 0);
                const source = &self.locks.items[lock_index];
                std.debug.assert(source.reservations == 0);
                existing.shared = source.shared;
                existing.exclusive = source.exclusive;
                source.shared = 0;
                source.exclusive = false;
                self.wakeLockWaiters(runtime, existing);
                self.wakeLockWaiters(runtime, source);
                self.allocator.free(new_path);
                if (source.waiters.items.len == 0) {
                    var removed = self.locks.orderedRemove(lock_index);
                    removed.deinit(self.allocator);
                }
                return;
            }
        }
        const lock = &self.locks.items[lock_index];
        self.allocator.free(lock.path);
        lock.path = new_path;
    }

    fn wakeLockWaiters(
        _: *FileLockRegistry,
        runtime: ?TaskRuntime,
        lock: *LockState,
    ) void {
        for (lock.waiters.items) |waiter| waiter.ready = true;
        if (runtime) |task_runtime| {
            _ = task_runtime.wake(
                futex_module.waitKey(.file_lock, lock.key),
                std.math.maxInt(usize),
            );
        }
    }

    fn reservePath(
        self: *FileLockRegistry,
        path: []const u8,
    ) (std.mem.Allocator.Error || error{WouldBlock})!void {
        const lock = try self.getOrCreate(path);
        if (lock.shared != 0 or lock.exclusive or lock.reservations != 0) return error.WouldBlock;
        lock.reservations += 1;
    }

    fn releasePathReservation(
        self: *FileLockRegistry,
        runtime: ?TaskRuntime,
        path: []const u8,
    ) void {
        const lock = self.find(path) orelse unreachable;
        std.debug.assert(lock.reservations > 0);
        lock.reservations -= 1;
        for (lock.waiters.items) |waiter| waiter.ready = true;
        const key = lock.key;
        const empty = lock.shared == 0 and !lock.exclusive and lock.reservations == 0 and lock.waiters.items.len == 0;
        if (runtime) |task_runtime| {
            _ = task_runtime.wake(
                futex_module.waitKey(.file_lock, key),
                std.math.maxInt(usize),
            );
        }
        if (empty) {
            const index = self.findIndex(path) orelse unreachable;
            var removed = self.locks.orderedRemove(index);
            removed.deinit(self.allocator);
        }
    }

    fn removeWaiter(self: *FileLockRegistry, waiter: *Waiter) void {
        for (self.locks.items, 0..) |*lock, lock_index| {
            for (lock.waiters.items, 0..) |candidate, waiter_index| {
                if (candidate != waiter) continue;
                _ = lock.waiters.swapRemove(waiter_index);
                self.allocator.destroy(waiter);
                self.removeLockIfEmpty(lock_index);
                return;
            }
        }
        unreachable;
    }

    fn removeLockIfEmpty(self: *FileLockRegistry, index: usize) void {
        const lock = &self.locks.items[index];
        if (lock.shared != 0 or lock.exclusive or lock.reservations != 0 or lock.waiters.items.len != 0) {
            return;
        }
        var removed = self.locks.orderedRemove(index);
        removed.deinit(self.allocator);
    }

    fn retireWaiters(self: *FileLockRegistry, owner: *anyopaque) void {
        for (self.locks.items) |*lock| {
            var index: usize = 0;
            while (index < lock.waiters.items.len) {
                const waiter = lock.waiters.items[index];
                if (waiter.owner != owner) {
                    index += 1;
                    continue;
                }
                if (!waiter.task_owned) {
                    waiter.ready = true;
                    index += 1;
                    continue;
                }
                _ = lock.waiters.swapRemove(index);
                self.allocator.destroy(waiter);
            }
        }
    }
};

/// Coordinates pathname users with rename/delete without serializing
/// operations on unrelated files. States are separately allocated so a task
/// may safely park while the index grows.
const PathGate = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayList(*State) = .empty,
    next_key: usize = 1,

    const key_base = @as(usize, 1) << (@bitSizeOf(usize) - 5);

    const Owner = struct {
        backend: *anyopaque,
        task_id: ?u64,

        fn eql(a: Owner, b: Owner) bool {
            return a.backend == b.backend and a.task_id == b.task_id;
        }
    };

    const Waiter = struct {
        owner: *anyopaque,
        task_owned: bool,
        ready: bool = false,
    };

    const State = struct {
        path: []u8,
        key: usize,
        active: std.ArrayList(Owner) = .empty,
        reservation: ?Owner = null,
        waiters: std.ArrayList(*Waiter) = .empty,

        fn deinit(state: *State, allocator: std.mem.Allocator) void {
            allocator.free(state.path);
            state.active.deinit(allocator);
            for (state.waiters.items) |waiter| allocator.destroy(waiter);
            state.waiters.deinit(allocator);
            allocator.destroy(state);
        }
    };

    fn init(allocator: std.mem.Allocator) PathGate {
        return .{ .allocator = allocator };
    }

    fn deinit(gate: *PathGate) void {
        for (gate.states.items) |state| state.deinit(gate.allocator);
        gate.states.deinit(gate.allocator);
        gate.* = undefined;
    }

    fn find(gate: *PathGate, path: []const u8) ?*State {
        for (gate.states.items) |state| {
            if (std.mem.eql(u8, state.path, path)) return state;
        }
        return null;
    }

    fn getOrCreate(gate: *PathGate, path: []const u8) std.mem.Allocator.Error!*State {
        if (gate.find(path)) |state| return state;
        const state = try gate.allocator.create(State);
        errdefer gate.allocator.destroy(state);
        const owned_path = try gate.allocator.dupe(u8, path);
        errdefer gate.allocator.free(owned_path);
        state.* = .{
            .path = owned_path,
            .key = key_base + gate.next_key,
        };
        gate.next_key += 1;
        try gate.states.append(gate.allocator, state);
        return state;
    }

    fn owner(backend: *anyopaque, runtime: ?TaskRuntime) Owner {
        return .{
            .backend = backend,
            .task_id = if (runtime) |task_runtime| task_runtime.currentTaskId() else null,
        };
    }

    fn wait(gate: *PathGate, backend: *anyopaque, runtime: ?TaskRuntime, state: *State) std.mem.Allocator.Error!void {
        const task_runtime = runtime orelse @panic("pathname contention requires an attached task runtime");
        const waiter = try gate.allocator.create(Waiter);
        errdefer gate.allocator.destroy(waiter);
        waiter.* = .{
            .owner = backend,
            .task_owned = task_runtime.inTask(),
        };
        try state.waiters.append(gate.allocator, waiter);
        if (waiter.task_owned) {
            task_runtime.block(futex_module.waitKey(.file_lock, state.key));
        } else {
            task_runtime.runUntilDone(&waiter.ready);
        }
        gate.removeWaiter(waiter);
    }

    fn acquire(gate: *PathGate, backend: *anyopaque, runtime: ?TaskRuntime, path: []const u8) std.mem.Allocator.Error!void {
        const lease_owner = owner(backend, runtime);
        while (true) {
            const state = try gate.getOrCreate(path);
            errdefer gate.removeIfEmpty(state);
            if (state.reservation == null) {
                try state.active.append(gate.allocator, lease_owner);
                return;
            }
            try gate.wait(backend, runtime, state);
        }
    }

    fn release(gate: *PathGate, backend: *anyopaque, runtime: ?TaskRuntime, path: []const u8) void {
        const state = gate.find(path) orelse unreachable;
        const lease_owner = owner(backend, runtime);
        for (state.active.items, 0..) |candidate, index| {
            if (!candidate.eql(lease_owner)) continue;
            _ = state.active.swapRemove(index);
            gate.wake(runtime, state);
            gate.removeIfEmpty(state);
            return;
        }
        unreachable;
    }

    fn reserve(gate: *PathGate, backend: *anyopaque, runtime: ?TaskRuntime, first_path: []const u8, second_path: ?[]const u8) std.mem.Allocator.Error!void {
        const reservation_owner = owner(backend, runtime);
        var reserved = false;
        errdefer if (reserved) gate.releaseReservation(runtime, first_path, second_path);
        while (true) {
            const first = try gate.getOrCreate(first_path);
            errdefer gate.removeIfEmpty(first);
            const second = if (second_path) |path|
                if (std.mem.eql(u8, first_path, path)) first else try gate.getOrCreate(path)
            else
                null;
            errdefer if (second) |state| if (state != first) gate.removeIfEmpty(state);
            const blocked = if (first.reservation != null)
                first
            else if (second) |state|
                if (state.reservation != null) state else null
            else
                null;
            if (blocked) |state| {
                try gate.wait(backend, runtime, state);
                continue;
            }
            first.reservation = reservation_owner;
            if (second) |state| state.reservation = reservation_owner;
            reserved = true;
            while (first.active.items.len != 0 or if (second) |state| state.active.items.len != 0 else false) {
                const state = if (first.active.items.len != 0) first else second.?;
                try gate.wait(backend, runtime, state);
            }
            return;
        }
    }

    fn releaseReservation(gate: *PathGate, runtime: ?TaskRuntime, first_path: []const u8, second_path: ?[]const u8) void {
        const first = gate.find(first_path) orelse unreachable;
        first.reservation = null;
        gate.wake(runtime, first);
        if (second_path) |path| if (!std.mem.eql(u8, first_path, path)) {
            const second = gate.find(path) orelse unreachable;
            second.reservation = null;
            gate.wake(runtime, second);
            gate.removeIfEmpty(second);
        };
        gate.removeIfEmpty(first);
    }

    fn wake(_: *PathGate, runtime: ?TaskRuntime, state: *State) void {
        for (state.waiters.items) |waiter| waiter.ready = true;
        if (runtime) |task_runtime| {
            _ = task_runtime.wake(futex_module.waitKey(.file_lock, state.key), std.math.maxInt(usize));
        }
    }

    fn removeWaiter(gate: *PathGate, waiter: *Waiter) void {
        for (gate.states.items) |state| {
            for (state.waiters.items, 0..) |candidate, index| {
                if (candidate != waiter) continue;
                _ = state.waiters.swapRemove(index);
                gate.allocator.destroy(waiter);
                gate.removeIfEmpty(state);
                return;
            }
        }
        unreachable;
    }

    fn removeIfEmpty(gate: *PathGate, state: *State) void {
        if (state.active.items.len != 0 or state.reservation != null or state.waiters.items.len != 0) return;
        for (gate.states.items, 0..) |candidate, index| {
            if (candidate != state) continue;
            _ = gate.states.swapRemove(index);
            state.deinit(gate.allocator);
            return;
        }
        unreachable;
    }

    fn retireInactive(gate: *PathGate, backend: *anyopaque, control: ?ProcessTaskControl, runtime: ?TaskRuntime) void {
        const task_control = control orelse return;
        var state_index: usize = 0;
        while (state_index < gate.states.items.len) {
            const state = gate.states.items[state_index];
            var changed = false;
            var active_index: usize = 0;
            while (active_index < state.active.items.len) {
                const lease_owner = state.active.items[active_index];
                if (lease_owner.backend != backend or lease_owner.task_id == null or task_control.taskActive(lease_owner.task_id.?)) {
                    active_index += 1;
                    continue;
                }
                _ = state.active.swapRemove(active_index);
                changed = true;
            }
            if (state.reservation) |reservation_owner| {
                if (reservation_owner.backend == backend and reservation_owner.task_id != null and !task_control.taskActive(reservation_owner.task_id.?)) {
                    state.reservation = null;
                    changed = true;
                }
            }
            var waiter_index: usize = 0;
            while (waiter_index < state.waiters.items.len) {
                const waiter = state.waiters.items[waiter_index];
                if (waiter.owner != backend or !waiter.task_owned) {
                    waiter_index += 1;
                    continue;
                }
                _ = state.waiters.swapRemove(waiter_index);
                gate.allocator.destroy(waiter);
                changed = true;
            }
            if (changed) gate.wake(runtime, state);
            if (state.active.items.len == 0 and state.reservation == null and state.waiters.items.len == 0) {
                _ = gate.states.swapRemove(state_index);
                state.deinit(gate.allocator);
            } else {
                state_index += 1;
            }
        }
    }
};

pub const FutexWaitResult = futex_module.FutexWaitResult;
pub const FutexWaitSet = futex_module.FutexWaitSet;
pub const ProcessId = @import("task.zig").ProcessId;
pub const ProcessTaskControl = @import("task.zig").ProcessTaskControl;
pub const TaskRuntime = @import("task.zig").TaskRuntime;

pub const Backend = struct {
    allocator: std.mem.Allocator,
    world: *World,
    disk: disk_module.Disk,
    sector_size: u64,
    network_control: network_module.AnyNetworkControl = network_module.AnyNetworkControl.unavailable(),
    process_registry: ?*ProcessRegistry = null,
    process_node: ?network_module.NodeId = null,
    process_alive: bool = true,
    next_network_node: network_module.NodeId = 0,
    futex_wait_set: ?FutexWaitSet = null,
    task_runtime: ?TaskRuntime = null,
    async_closures: std.ArrayList(*AsyncClosure) = .empty,
    group_closures: std.ArrayList(*GroupClosure) = .empty,
    group_states: std.ArrayList(*GroupState) = .empty,
    next_group_id: usize = 1,
    futex_keys: std.ArrayList(FutexKeyEntry) = .empty,
    next_futex_key: usize = 1,
    /// The index table may grow while file operations are suspended on disk
    /// latency, so metadata lives in separately allocated, stable storage.
    files: std.ArrayList(*FileMeta) = .empty,
    retired_file_paths: std.ArrayList([]u8) = .empty,
    directory_handles: std.ArrayList(DirectoryHandle) = .empty,
    handles: std.ArrayList(HandleEntry) = .empty,
    next_handle: SocketHandle = 1000,
    next_ephemeral_port: u16 = ephemeral_port_min,
    locks: FileLockRegistry,
    path_gate: PathGate,
    /// Live operation-scoped buffers (sector scratch, path copies) held
    /// across disk-latency suspension points. A task killed while parked
    /// mid-operation never runs its defers, so these register here and any
    /// killed-task survivors are swept after task retirement.
    op_scratch: std.ArrayList(OpScratch) = .empty,

    pub const HandleEntry = struct {
        handle: SocketHandle,
        state: State,

        pub const State = union(enum) {
            listener: *ListenerState,
            connection: *ConnectionState,
            file: *FileState,
        };
    };

    pub const FileMeta = struct {
        path: []u8,
        inode: Io.File.INode,
        len: u64 = 0,
        mtime: Io.Timestamp = .zero,
        deleted: bool = false,
        /// Set when a disk crash invalidates cached state. The length is
        /// re-derived from disk truth on next touch; the timestamp is kept,
        /// since filesystem timestamps survive a real machine crash.
        stale: bool = false,

        fn deinit(self: *FileMeta, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            self.* = undefined;
        }
    };

    pub const DirectoryHandle = struct {
        handle: Io.Dir.Handle,
        path: []u8,
        iterate: bool,

        fn deinit(self: *DirectoryHandle, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            self.* = undefined;
        }
    };

    const OpScratch = struct {
        buffer: []u8,
        task_id: ?u64,
    };

    const FutexKeyEntry = struct {
        address: usize,
        key: usize,
        waiters: usize = 0,
    };

    pub const SocketRef = struct {
        backend: *Backend,
        handle: SocketHandle,
    };

    pub const ListenerRef = struct {
        backend: *Backend,
        handle: SocketHandle,
        state: *ListenerState,
    };

    pub const ListenerState = struct {
        address: Io.net.IpAddress,
        node: ?network_module.NodeId = null,
        pending: std.ArrayList(SocketHandle) = .empty,
        closed: bool = false,
        waiters: usize = 0,
    };

    pub const ConnectionState = struct {
        address: Io.net.IpAddress,
        node: ?network_module.NodeId = null,
        inbox: std.ArrayList(u8) = .empty,
        read_error: ?Io.net.Stream.Reader.Error = null,
        peer: ?SocketRef = null,
        delivery_floor_ns: u64 = 0,
        closed: bool = false,
        waiters: usize = 0,
    };

    pub const FileState = struct {
        target: Target,
        read: bool,
        write: bool,
        lock: Io.File.Lock = .none,
        lock_path: ?[]u8 = null,
        cursor: u64 = 0,
        closed: bool = false,

        pub const Target = union(enum) {
            file: usize,
            directory: []u8,
        };

        fn deinit(self: *FileState, allocator: std.mem.Allocator) void {
            switch (self.target) {
                .file => {},
                .directory => |path| allocator.free(path),
            }
            if (self.lock_path) |path| allocator.free(path);
            allocator.destroy(self);
        }
    };

    pub const FileLockRekey = struct {
        registry_path: ?[]u8 = null,
        handle_paths: std.ArrayList(HandlePath) = .empty,

        pub const HandlePath = struct {
            backend: *Backend,
            state: *FileState,
            path: []u8,
        };

        pub fn deinit(self: *FileLockRekey, allocator: std.mem.Allocator) void {
            if (self.registry_path) |path| allocator.free(path);
            for (self.handle_paths.items) |entry| entry.backend.allocator.free(entry.path);
            self.handle_paths.deinit(allocator);
            self.* = undefined;
        }
    };

    pub const FileMetaRename = struct {
        entries: std.ArrayList(Entry) = .empty,

        pub const Entry = struct {
            backend: *Backend,
            index: usize,
            path: []u8,
        };

        pub fn deinit(self: *FileMetaRename, allocator: std.mem.Allocator) void {
            for (self.entries.items) |entry| entry.backend.allocator.free(entry.path);
            self.entries.deinit(allocator);
            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator, world: *World, disk: disk_module.Disk, sector_size: u64) Backend {
        return .{
            .allocator = allocator,
            .world = world,
            .disk = disk,
            .sector_size = sector_size,
            .locks = .init(allocator),
            .path_gate = .init(allocator),
        };
    }

    pub fn deinit(self: *Backend) void {
        for (self.handles.items) |entry| self.deinitHandleState(entry.state);
        self.handles.deinit(self.allocator);
        self.futex_keys.deinit(self.allocator);
        for (self.async_closures.items) |closure| closure.destroy(self.allocator);
        self.async_closures.deinit(self.allocator);
        for (self.group_closures.items) |closure| closure.destroy(self.allocator);
        self.group_closures.deinit(self.allocator);
        for (self.group_states.items) |state| self.allocator.destroy(state);
        self.group_states.deinit(self.allocator);
        for (self.files.items) |file_meta| {
            file_meta.deinit(self.allocator);
            self.allocator.destroy(file_meta);
        }
        self.files.deinit(self.allocator);
        for (self.retired_file_paths.items) |path| self.allocator.free(path);
        self.retired_file_paths.deinit(self.allocator);
        for (self.directory_handles.items) |*handle| handle.deinit(self.allocator);
        self.directory_handles.deinit(self.allocator);
        self.locks.deinit();
        self.path_gate.deinit();
        for (self.op_scratch.items) |entry| self.allocator.free(entry.buffer);
        self.op_scratch.deinit(self.allocator);
        self.* = undefined;
    }

    /// Allocate an operation-scoped buffer that survives task kill without
    /// leaking. Pair with `freeOpScratch` on the normal path.
    pub fn allocOpScratch(self: *Backend, len: usize) std.mem.Allocator.Error![]u8 {
        const buffer = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(buffer);
        try self.op_scratch.append(self.allocator, .{
            .buffer = buffer,
            .task_id = self.currentTaskId(),
        });
        return buffer;
    }

    /// Register an externally allocated operation-scoped buffer for
    /// kill-safe cleanup. On failure the caller still owns the buffer.
    pub fn registerOpScratch(self: *Backend, buffer: []u8) std.mem.Allocator.Error!void {
        try self.op_scratch.append(self.allocator, .{
            .buffer = buffer,
            .task_id = self.currentTaskId(),
        });
    }

    pub fn freeOpScratch(self: *Backend, buffer: []const u8) void {
        self.releaseOpScratch(buffer);
        self.allocator.free(buffer);
    }

    /// Unregister a buffer whose ownership moved elsewhere (for example into
    /// `FileMeta`) without freeing it.
    pub fn releaseOpScratch(self: *Backend, buffer: []const u8) void {
        for (self.op_scratch.items, 0..) |candidate, index| {
            if (candidate.buffer.ptr == buffer.ptr) {
                _ = self.op_scratch.swapRemove(index);
                return;
            }
        }
        unreachable; // released a buffer that was never registered
    }

    fn currentTaskId(self: *Backend) ?u64 {
        const runtime = self.task_runtime orelse return null;
        return runtime.currentTaskId();
    }

    fn sweepInactiveOpScratch(self: *Backend, task_control: ?ProcessTaskControl) void {
        const control = task_control orelse return;

        var index: usize = 0;
        while (index < self.op_scratch.items.len) {
            const entry = self.op_scratch.items[index];
            const task_id = entry.task_id orelse {
                index += 1;
                continue;
            };
            if (control.taskActive(task_id)) {
                index += 1;
                continue;
            }
            self.allocator.free(entry.buffer);
            _ = self.op_scratch.swapRemove(index);
        }
    }

    pub fn io(self: *Backend) Io {
        return .{
            .userdata = self,
            .vtable = &sim_vtable,
        };
    }

    pub fn processIsAlive(self: *const Backend) bool {
        return self.process_alive;
    }

    pub fn attachFutexWaitSet(self: *Backend, wait_set: FutexWaitSet) void {
        self.futex_wait_set = wait_set;
    }

    /// Attach a cooperative task runtime, enabling `Io.async` and
    /// `Io.concurrent` to spawn deterministic scheduler tasks.
    pub fn attachTaskRuntime(self: *Backend, runtime: TaskRuntime) void {
        self.task_runtime = runtime;
    }

    pub fn attachNetworkControl(self: *Backend, control: network_module.AnyNetworkControl) void {
        self.network_control = control;
    }

    pub fn attachProcessRegistry(self: *Backend, registry: *ProcessRegistry, node: network_module.NodeId) void {
        self.process_registry = registry;
        self.process_node = node;
    }

    fn findFutexKeyEntry(self: *Backend, address: usize) ?usize {
        for (self.futex_keys.items, 0..) |entry, index| {
            if (entry.address == address) return index;
        }
        return null;
    }

    fn retireFutexKeyAt(self: *Backend, index: usize) void {
        std.debug.assert(self.futex_keys.items[index].waiters == 0);
        _ = self.futex_keys.swapRemove(index);
    }

    pub fn beginFutexWait(self: *Backend, ptr: *const u32) usize {
        if (self.process_registry) |registry| {
            const key = registry.beginFutexWait(self, ptr) catch @panic("failed to allocate sim futex key");
            return futex_module.waitKey(.futex, key);
        }

        const address = @intFromPtr(ptr);
        // Sim futexes intentionally key by pointer identity within a backend.
        // If an allocator later reuses the address for a different futex after
        // all old waiters are gone, a fresh logical key is also valid: no
        // live wait can observe the old key. Raw addresses never enter traces.
        if (self.findFutexKeyEntry(address)) |index| {
            self.futex_keys.items[index].waiters += 1;
            return futex_module.waitKey(.futex, self.futex_keys.items[index].key);
        }

        const key = self.next_futex_key;
        self.next_futex_key += 1;
        self.futex_keys.append(self.allocator, .{
            .address = address,
            .key = key,
            .waiters = 1,
        }) catch @panic("failed to allocate sim futex key");
        return futex_module.waitKey(.futex, key);
    }

    pub fn endFutexWait(self: *Backend, ptr: *const u32) void {
        if (self.process_registry) |registry| {
            registry.endFutexWait(self, ptr);
            return;
        }

        const address = @intFromPtr(ptr);
        const index = self.findFutexKeyEntry(address) orelse unreachable;
        std.debug.assert(self.futex_keys.items[index].waiters > 0);
        self.futex_keys.items[index].waiters -= 1;
        if (self.futex_keys.items[index].waiters == 0) self.retireFutexKeyAt(index);
    }

    pub fn futexWakeKey(self: *Backend, ptr: *const u32) ?usize {
        if (self.process_registry) |registry| {
            const key = registry.futexWakeKey(self, ptr) orelse return null;
            return futex_module.waitKey(.futex, key);
        }

        const address = @intFromPtr(ptr);
        const index = self.findFutexKeyEntry(address) orelse return null;
        return futex_module.waitKey(.futex, self.futex_keys.items[index].key);
    }

    pub fn listenerWaitKey(_: *Backend, handle: SocketHandle) usize {
        return futex_module.waitKey(.listener, @intCast(handle));
    }

    pub fn connectionWaitKey(_: *Backend, handle: SocketHandle) usize {
        return futex_module.waitKey(.connection, @intCast(handle));
    }

    pub fn sleepWaitKey(_: *Backend) usize {
        return futex_module.waitKey(.sleep, 0);
    }

    /// Wake tasks blocked on a connection handle becoming ready, if a
    /// scheduler is attached. No-op in the bare-backend case.
    pub fn wakeConnection(self: *Backend, handle: SocketHandle, count: usize) void {
        if (self.futex_wait_set) |wait_set| {
            _ = wait_set.wake(self.connectionWaitKey(handle), count);
        }
    }

    /// Wake tasks blocked on a listener handle becoming ready, if a
    /// scheduler is attached. No-op in the bare-backend case.
    pub fn wakeListener(self: *Backend, handle: SocketHandle, count: usize) void {
        if (self.futex_wait_set) |wait_set| {
            _ = wait_set.wake(self.listenerWaitKey(handle), count);
        }
    }

    pub fn allocateNetworkNode(self: *Backend) error{NetworkDown}!?network_module.NodeId {
        if (!self.process_alive) return error.NetworkDown;
        const process_count = network_module.internal.processCountFromControl(self.network_control) orelse return null;
        if (self.process_node) |node| {
            if (@as(usize, node) >= process_count) return error.NetworkDown;
            return node;
        }

        if (@as(usize, self.next_network_node) >= process_count) return error.NetworkDown;
        const node = self.next_network_node;
        self.next_network_node += 1;
        return node;
    }

    pub fn createHandle(self: *Backend, state: HandleEntry.State) std.mem.Allocator.Error!SocketHandle {
        const handle = self.allocateHandle();
        try self.handles.append(self.allocator, .{
            .handle = handle,
            .state = state,
        });
        return handle;
    }

    fn allocateHandle(self: *Backend) SocketHandle {
        if (self.process_registry) |registry| return registry.allocateHandle();
        const handle = self.next_handle;
        self.next_handle += 1;
        return handle;
    }

    fn allocateGroupId(self: *Backend) usize {
        if (self.process_registry) |registry| return registry.allocateGroupId();
        const id = self.next_group_id;
        self.next_group_id += 1;
        return id;
    }

    fn deinitHandleState(self: *Backend, state: HandleEntry.State) void {
        switch (state) {
            .listener => |listener_state| {
                listener_state.pending.deinit(self.allocator);
                self.allocator.destroy(listener_state);
            },
            .connection => |connection_state| {
                connection_state.inbox.deinit(self.allocator);
                self.allocator.destroy(connection_state);
            },
            .file => |file_state| {
                self.releaseFileLock(file_state);
                file_state.deinit(self.allocator);
            },
        }
    }

    fn retireHandleAt(self: *Backend, index: usize) void {
        const entry = self.handles.swapRemove(index);
        self.deinitHandleState(entry.state);
    }

    fn closeConnectionState(
        self: *Backend,
        handle: SocketHandle,
        connection_state: *ConnectionState,
        reset_peer: bool,
    ) void {
        connection_state.closed = true;
        if (connection_state.node) |node| {
            _ = network_module.internal.discardStreamFramesFromControl(
                self.network_control,
                node,
                @intCast(handle),
            );
        }
        self.wakeConnection(handle, std.math.maxInt(usize));
        // A writer blocked on shared stream backpressure parks on the
        // world-global key, not its handle key; teardown (close, shutdown,
        // process kill) must wake it so it observes the close or reset
        // instead of staying parked forever.
        if (self.futex_wait_set) |wait_set| {
            _ = wait_set.wake(futex_module.stream_backpressure_wait_key, std.math.maxInt(usize));
        }
        if (connection_state.peer) |peer| {
            if (reset_peer) {
                if (peer.backend.connection(peer.handle)) |peer_state| {
                    if (!peer_state.closed and peer_state.read_error == null) {
                        peer_state.read_error = error.ConnectionResetByPeer;
                    }
                }
            }
            peer.backend.wakeConnection(peer.handle, std.math.maxInt(usize));
        }
    }

    fn closePendingConnections(self: *Backend, listener_state: *ListenerState) void {
        while (listener_state.pending.items.len > 0) {
            const pending_handle = listener_state.pending.pop().?;
            for (self.handles.items, 0..) |entry, index| {
                if (entry.handle != pending_handle) continue;
                switch (entry.state) {
                    .connection => |connection_state| {
                        self.closeConnectionState(pending_handle, connection_state, true);
                        if (connection_state.waiters == 0) {
                            self.retireHandleAt(index);
                        }
                    },
                    .listener, .file => {},
                }
                break;
            }
        }
    }

    pub fn retireFileHandle(self: *Backend, handle: Io.File.Handle) void {
        const socket_handle: SocketHandle = @intCast(handle);
        for (self.handles.items, 0..) |entry, index| switch (entry.state) {
            .file => if (entry.handle == socket_handle) {
                self.retireHandleAt(index);
                return;
            },
            .listener, .connection => {},
        };
    }

    pub fn retireNetHandle(self: *Backend, handle: SocketHandle) void {
        for (self.handles.items, 0..) |entry, index| {
            if (entry.handle != handle) continue;
            switch (entry.state) {
                .listener => |listener_state| {
                    listener_state.closed = true;
                    self.unregisterListener(handle);
                    self.wakeListener(handle, std.math.maxInt(usize));
                    self.closePendingConnections(listener_state);
                    if (listener_state.waiters != 0) return;
                    self.retireClosedNetHandleIfIdle(handle);
                    return;
                },
                .connection => |connection_state| {
                    self.closeConnectionState(handle, connection_state, false);
                    if (connection_state.waiters != 0) return;
                },
                .file => {},
            }
            self.retireHandleAt(index);
            return;
        }
    }

    pub fn retireClosedNetHandleIfIdle(self: *Backend, handle: SocketHandle) void {
        for (self.handles.items, 0..) |entry, index| {
            if (entry.handle != handle) continue;
            switch (entry.state) {
                .listener => |listener_state| {
                    if (!listener_state.closed or listener_state.waiters != 0) return;
                },
                .connection => |connection_state| {
                    if (!connection_state.closed or connection_state.waiters != 0) return;
                },
                .file => return,
            }
            self.retireHandleAt(index);
            return;
        }
    }

    fn retireClosedNetHandlesAfterTaskKill(self: *Backend) void {
        var index: usize = 0;
        while (index < self.handles.items.len) {
            switch (self.handles.items[index].state) {
                .listener => |listener_state| {
                    if (listener_state.closed) {
                        self.retireHandleAt(index);
                        continue;
                    }
                },
                .connection => |connection_state| {
                    if (connection_state.closed) {
                        self.retireHandleAt(index);
                        continue;
                    }
                },
                .file => {},
            }
            index += 1;
        }
    }

    pub fn findEntry(self: *Backend, handle: SocketHandle) ?*HandleEntry {
        for (self.handles.items) |*entry| {
            if (entry.handle == handle) return entry;
        }
        return null;
    }

    pub fn findOpenListener(self: *Backend, address: *const Io.net.IpAddress) ?*HandleEntry {
        for (self.handles.items) |*entry| switch (entry.state) {
            .listener => |listener_state| {
                if (!listener_state.closed and listener_state.address.eql(address)) return entry;
            },
            .connection => {},
            .file => {},
        };
        return null;
    }

    pub fn findOpenListenerRef(self: *Backend, address: *const Io.net.IpAddress) ?ListenerRef {
        if (self.process_registry) |registry| return registry.findOpenListener(address);
        const entry = self.findOpenListener(address) orelse return null;
        return .{
            .backend = self,
            .handle = entry.handle,
            .state = entry.state.listener,
        };
    }

    pub const ephemeral_port_min: u16 = 49152;
    pub const ephemeral_port_max: u16 = 65535;

    /// Allocate a free port from the IANA dynamic range for a bind to port 0.
    /// The cursor rotates rather than reusing the lowest free port, and is
    /// shared across process backends so concurrent binds in a multi-process
    /// world cannot converge on the same candidate.
    pub fn allocateEphemeralPort(self: *Backend, address: *const Io.net.IpAddress) error{AddressInUse}!u16 {
        const range_len = @as(u17, ephemeral_port_max - ephemeral_port_min) + 1;
        var candidate = address.*;
        var attempts: u17 = 0;
        while (attempts < range_len) : (attempts += 1) {
            const port = self.takeEphemeralPortCursor();
            candidate.setPort(port);
            if (self.findOpenListenerRef(&candidate) == null) return port;
        }
        return error.AddressInUse;
    }

    fn takeEphemeralPortCursor(self: *Backend) u16 {
        const cursor = if (self.process_registry) |registry|
            &registry.next_ephemeral_port
        else
            &self.next_ephemeral_port;
        const port = cursor.*;
        cursor.* = if (port == ephemeral_port_max) ephemeral_port_min else port + 1;
        return port;
    }

    pub fn registerListener(self: *Backend, handle: SocketHandle, address: Io.net.IpAddress) std.mem.Allocator.Error!void {
        if (self.process_registry) |registry| {
            try registry.registerListener(self, handle, address);
        }
    }

    pub fn unregisterListener(self: *Backend, handle: SocketHandle) void {
        if (self.process_registry) |registry| registry.unregisterListener(self, handle);
    }

    pub fn listener(self: *Backend, handle: SocketHandle) ?*ListenerState {
        return switch ((self.findEntry(handle) orelse return null).state) {
            .listener => |state| state,
            .connection, .file => null,
        };
    }

    pub fn connection(self: *Backend, handle: SocketHandle) ?*ConnectionState {
        return switch ((self.findEntry(handle) orelse return null).state) {
            .listener, .file => null,
            .connection => |state| state,
        };
    }

    pub fn file(self: *Backend, handle: Io.File.Handle) ?*FileState {
        return switch ((self.findEntry(@intCast(handle)) orelse return null).state) {
            .listener, .connection => null,
            .file => |state| state,
        };
    }

    pub fn fileMeta(self: *Backend, file_state: *const FileState) *FileMeta {
        return self.files.items[file_state.target.file];
    }

    pub fn fileDirectoryPath(file_state: *const FileState) ?[]const u8 {
        return switch (file_state.target) {
            .file => null,
            .directory => |path| path,
        };
    }

    pub fn directoryPath(self: *Backend, dir: Io.Dir) ?[]const u8 {
        if (dir.handle == Io.Dir.cwd().handle) return ".";
        for (self.directory_handles.items) |handle| {
            if (handle.handle == dir.handle) return handle.path;
        }
        return null;
    }

    pub fn resolvePathAlloc(
        self: *Backend,
        dir: Io.Dir,
        sub_path: []const u8,
        kind: disk_module.LogicalPathKind,
    ) (std.mem.Allocator.Error || error{ InvalidPath, InvalidDirHandle })![]u8 {
        const absolute = sub_path.len > 0 and sub_path[0] == '/';
        var first_relative: usize = 0;
        if (absolute) {
            while (first_relative < sub_path.len and sub_path[first_relative] == '/') {
                first_relative += 1;
            }
        }
        const relative = sub_path[first_relative..];

        if (relative.len == 0) {
            if (kind != .directory) return error.InvalidPath;
            return try self.allocator.dupe(u8, ".");
        }

        const base = if (absolute) "." else self.directoryPath(dir) orelse return error.InvalidDirHandle;
        if (kind == .directory and std.mem.eql(u8, relative, ".")) {
            return try self.allocator.dupe(u8, base);
        }

        const resolved = if (std.mem.eql(u8, base, "."))
            try self.allocator.dupe(u8, relative)
        else
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, relative });
        errdefer self.allocator.free(resolved);
        disk_module.validateLogicalPath(resolved, kind) catch return error.InvalidPath;
        return resolved;
    }

    pub fn directoryExists(self: *Backend, path: []const u8) disk_module.DiskError!bool {
        _ = self.disk.statDir(.{ .path = path }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    pub fn createDirectory(self: *Backend, path: []const u8) disk_module.DiskError!void {
        try self.disk.createDir(.{ .path = path });
    }

    pub fn createDirectoryPath(self: *Backend, path: []const u8) disk_module.DiskError!Io.Dir.CreatePathStatus {
        if (try self.directoryExists(path)) return .existed;

        var created = false;
        var components = std.mem.splitScalar(u8, path, '/');
        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(self.allocator);
        while (components.next()) |component| {
            if (prefix.items.len != 0) try prefix.append(self.allocator, '/');
            try prefix.appendSlice(self.allocator, component);
            if (try self.directoryExists(prefix.items)) continue;
            self.createDirectory(prefix.items) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    if (try self.directoryExists(prefix.items)) continue;
                    return error.PathAlreadyExists;
                },
                else => return err,
            };
            created = true;
        }
        return if (created) .created else .existed;
    }

    pub fn openDirectoryHandle(self: *Backend, path: []const u8, iterate: bool) !Io.Dir {
        _ = try self.disk.statDir(.{ .path = path });
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const handle: Io.Dir.Handle = @intCast(self.allocateHandle());
        try self.directory_handles.append(self.allocator, .{
            .handle = handle,
            .path = owned_path,
            .iterate = iterate,
        });
        return .{ .handle = handle };
    }

    pub fn closeDirectoryHandle(self: *Backend, dir: Io.Dir) void {
        if (dir.handle == Io.Dir.cwd().handle) return;
        for (self.directory_handles.items, 0..) |handle, index| {
            if (handle.handle != dir.handle) continue;
            var removed = self.directory_handles.swapRemove(index);
            removed.deinit(self.allocator);
            return;
        }
    }

    pub fn directoryHandleCanIterate(self: *const Backend, dir: Io.Dir) bool {
        for (self.directory_handles.items) |handle| {
            if (handle.handle == dir.handle) return handle.iterate;
        }
        return false;
    }

    pub fn findFileMetaIndex(self: *Backend, path: []const u8) ?usize {
        for (self.files.items, 0..) |file_meta, index| {
            if (file_meta.deleted) continue;
            if (std.mem.eql(u8, file_meta.path, path)) return index;
        }
        return null;
    }

    /// Find a tombstoned entry whose deletion may have been rolled back by
    /// a disk crash. Only stale tombstones qualify: a live tombstone is an
    /// authoritative deletion, but after a crash the disk may have
    /// resurrected the file.
    pub fn findStaleDeletedFileMetaIndex(self: *Backend, path: []const u8) ?usize {
        for (self.files.items, 0..) |file_meta, index| {
            if (!file_meta.deleted or !file_meta.stale) continue;
            if (std.mem.eql(u8, file_meta.path, path)) return index;
        }
        return null;
    }

    pub fn createFileMeta(self: *Backend, path: []const u8) std.mem.Allocator.Error!usize {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const inode = fileInodeForPath(path);

        // Keep tombstones allocated: a disk operation that started before a
        // delete may still hold this identity when it resumes.
        const file_meta = try self.allocator.create(FileMeta);
        errdefer self.allocator.destroy(file_meta);
        file_meta.* = .{
            .path = owned_path,
            .inode = inode,
        };
        try self.files.append(self.allocator, file_meta);
        return self.files.items.len - 1;
    }

    pub fn discardFileMeta(self: *Backend, index: usize) void {
        self.files.items[index].deleted = true;
        self.files.items[index].stale = false;
        self.files.items[index].len = 0;
    }

    pub fn discardFileMetaForPathAcrossProcesses(self: *Backend, path: []const u8) void {
        if (self.process_registry) |registry| {
            for (registry.backends) |*backend| {
                backend.discardFileMetaForPath(path);
            }
            return;
        }

        self.discardFileMetaForPath(path);
    }

    fn discardFileMetaForPath(self: *Backend, path: []const u8) void {
        const index = self.findFileMetaIndex(path) orelse return;
        self.closeFileHandlesForIndex(index);
        self.discardFileMeta(index);
    }

    fn fileInodeForPath(path: []const u8) Io.File.INode {
        return @intCast(std.hash.Wyhash.hash(0, path));
    }

    pub fn nowTimestamp(self: *const Backend) Io.Timestamp {
        return Io.Timestamp.fromNanoseconds(@intCast(self.world.now()));
    }

    pub const KillOptions = struct {
        invalidate_files: bool = false,
    };

    /// Tear down process-local runtime state.
    ///
    /// This is shared by explicit process kill and disk crash. Both close
    /// handles and cancel process-owned async closures; disk crash also marks
    /// cached file metadata stale so restart re-derives it from disk truth.
    pub fn killProcess(self: *Backend, options: KillOptions) void {
        self.process_alive = false;
        var index: usize = 0;
        while (index < self.handles.items.len) {
            const entry = &self.handles.items[index];
            const handle = entry.handle;
            switch (entry.state) {
                .file => {
                    self.retireHandleAt(index);
                    continue;
                },
                .listener => |listener_state| {
                    listener_state.closed = true;
                    self.unregisterListener(handle);
                    self.wakeListener(handle, std.math.maxInt(usize));
                    self.closePendingConnections(listener_state);
                    if (listener_state.waiters == 0) {
                        self.retireClosedNetHandleIfIdle(handle);
                        index = 0;
                        continue;
                    }
                },
                .connection => |connection_state| {
                    self.closeConnectionState(handle, connection_state, true);
                    if (connection_state.waiters == 0) {
                        self.retireHandleAt(index);
                        continue;
                    }
                },
            }
            index += 1;
        }

        for (self.async_closures.items) |closure| closure.cancelForKill();
        for (self.group_closures.items) |closure| closure.cancelForKill();
        self.releaseCompletedGroupStatesForKill();
        for (self.directory_handles.items) |*handle| handle.deinit(self.allocator);
        self.directory_handles.clearRetainingCapacity();

        if (options.invalidate_files) {
            // Tombstones go stale too: a crash can roll back an unsynced
            // deletion, in which case the tombstoned entry must be revivable
            // with its timestamps intact.
            for (self.files.items) |file_meta| {
                file_meta.stale = true;
            }
        }
    }

    fn releaseCompletedGroupStatesForKill(self: *Backend) void {
        // `killProcessTasks` destroys suspended fibers immediately after this
        // backend teardown returns. Clear completed group tokens while their
        // owning task stacks are still mapped; a task killed inside
        // `Group.await` will never resume to release its state itself.
        var index: usize = 0;
        while (index < self.group_states.items.len) {
            const state = self.group_states.items[index];
            if (!state.done) {
                index += 1;
                continue;
            }
            releaseGroupState(state);
        }
    }

    /// Invalidate process-local state after a disk crash.
    ///
    /// A disk crash models a machine crash, which also kills the process:
    /// every open handle dies with it. File metadata is marked stale and
    /// re-derived from disk truth on first touch; timestamps are kept since
    /// filesystem timestamps survive a real machine crash.
    pub fn onDiskCrash(self: *Backend) void {
        self.killProcess(.{ .invalidate_files = true });
    }

    pub fn closeFileHandlesForIndex(self: *Backend, file_index: usize) void {
        var index: usize = 0;
        while (index < self.handles.items.len) {
            switch (self.handles.items[index].state) {
                .file => |file_state| {
                    switch (file_state.target) {
                        .file => |target_index| if (target_index == file_index) {
                            self.retireHandleAt(index);
                            continue;
                        },
                        .directory => {},
                    }
                },
                .listener, .connection => {},
            }
            index += 1;
        }
    }

    fn retireFutexKeysForBackend(self: *Backend) void {
        if (self.process_registry) |registry| {
            registry.retireFutexKeysForBackend(self);
            return;
        }
        self.futex_keys.clearRetainingCapacity();
    }

    pub fn openFileHandle(
        self: *Backend,
        file_index: usize,
        read: bool,
        write: bool,
        lock: Io.File.Lock,
        lock_nonblocking: bool,
    ) (std.mem.Allocator.Error || error{WouldBlock})!Io.File {
        var lock_acquire_path = self.files.items[file_index].path;
        while (true) {
            try self.fileLockRegistry().acquire(
                self,
                self.task_runtime,
                lock_acquire_path,
                lock,
                lock_nonblocking,
            );
            const current_path = self.files.items[file_index].path;
            if (std.mem.eql(u8, lock_acquire_path, current_path)) break;
            self.fileLockRegistry().release(self.task_runtime, lock_acquire_path, lock);
            lock_acquire_path = current_path;
        }
        errdefer self.fileLockRegistry().release(
            self.task_runtime,
            lock_acquire_path,
            lock,
        );
        const lock_path = if (lock == .none)
            null
        else
            try self.allocator.dupe(u8, lock_acquire_path);
        errdefer if (lock_path) |path| self.allocator.free(path);
        const file_state = try self.allocator.create(FileState);
        errdefer self.allocator.destroy(file_state);
        file_state.* = .{
            .target = .{ .file = file_index },
            .read = read,
            .write = write,
            .lock = lock,
            .lock_path = lock_path,
        };

        const handle = try self.createHandle(.{ .file = file_state });
        return .{
            .handle = @intCast(handle),
            .flags = .{ .nonblocking = false },
        };
    }

    fn releaseFileLock(self: *Backend, state: *const FileState) void {
        const path = state.lock_path orelse return;
        self.fileLockRegistry().release(self.task_runtime, path, state.lock);
    }

    fn fileLockRegistry(self: *Backend) *FileLockRegistry {
        if (self.process_registry) |registry| return &registry.locks;
        return &self.locks;
    }

    fn pathGate(self: *Backend) *PathGate {
        if (self.process_registry) |registry| return &registry.path_gate;
        return &self.path_gate;
    }

    pub fn acquireFilePathLease(self: *Backend, path: []const u8) (std.mem.Allocator.Error || error{ProcessKilled})!void {
        if (!self.process_alive) return error.ProcessKilled;
        try self.pathGate().acquire(self, self.task_runtime, path);
    }

    pub fn releaseFilePathLease(self: *Backend, path: []const u8) void {
        self.pathGate().release(self, self.task_runtime, path);
    }

    pub fn reserveFileMutationPaths(self: *Backend, first_path: []const u8, second_path: ?[]const u8) (std.mem.Allocator.Error || error{ProcessKilled})!void {
        if (!self.process_alive) return error.ProcessKilled;
        try self.pathGate().reserve(self, self.task_runtime, first_path, second_path);
    }

    pub fn releaseFileMutationPaths(self: *Backend, first_path: []const u8, second_path: ?[]const u8) void {
        self.pathGate().releaseReservation(self.task_runtime, first_path, second_path);
    }

    pub fn reserveFileLockPath(self: *Backend, path: []const u8) (std.mem.Allocator.Error || error{WouldBlock})!void {
        try self.fileLockRegistry().reservePath(path);
    }

    pub fn releaseFileLockPathReservation(self: *Backend, path: []const u8) void {
        self.fileLockRegistry().releasePathReservation(self.task_runtime, path);
    }

    pub fn prepareFileMetaRename(
        self: *Backend,
        old_path: []const u8,
        new_path: []const u8,
    ) std.mem.Allocator.Error!FileMetaRename {
        var prepared: FileMetaRename = .{};
        errdefer prepared.deinit(self.allocator);

        if (self.process_registry) |registry| {
            for (registry.backends) |*backend| {
                try backend.prepareFileMetaPath(self.allocator, &prepared, old_path, new_path);
            }
        } else {
            try self.prepareFileMetaPath(self.allocator, &prepared, old_path, new_path);
        }

        return prepared;
    }

    fn prepareFileMetaPath(
        self: *Backend,
        list_allocator: std.mem.Allocator,
        prepared: *FileMetaRename,
        old_path: []const u8,
        new_path: []const u8,
    ) std.mem.Allocator.Error!void {
        const index = self.findFileMetaIndex(old_path) orelse return;
        try self.retired_file_paths.ensureUnusedCapacity(self.allocator, 1);
        const owned_path = try self.allocator.dupe(u8, new_path);
        var path_owned = true;
        errdefer if (path_owned) self.allocator.free(owned_path);
        try prepared.entries.append(list_allocator, .{
            .backend = self,
            .index = index,
            .path = owned_path,
        });
        path_owned = false;
    }

    pub fn commitFileMetaRename(
        self: *Backend,
        new_path: []const u8,
        prepared: *FileMetaRename,
    ) void {
        self.discardFileMetaForPathAcrossProcesses(new_path);

        for (prepared.entries.items) |entry| {
            const old_path = entry.backend.files.items[entry.index].path;
            if (entry.backend.fileLockPathHasWaiters(old_path)) {
                entry.backend.retired_file_paths.appendAssumeCapacity(old_path);
            } else {
                entry.backend.allocator.free(old_path);
            }
            entry.backend.files.items[entry.index].path = entry.path;
        }
        prepared.entries.clearRetainingCapacity();
    }

    fn fileLockPathHasWaiters(self: *Backend, path: []const u8) bool {
        const lock = self.fileLockRegistry().find(path) orelse return false;
        return lock.waiters.items.len != 0;
    }

    pub fn prepareFileLockRekey(
        self: *Backend,
        old_path: []const u8,
        new_path: []const u8,
    ) std.mem.Allocator.Error!FileLockRekey {
        var prepared: FileLockRekey = .{};
        errdefer prepared.deinit(self.allocator);

        if (self.fileLockRegistry().find(old_path) != null) {
            prepared.registry_path = try self.allocator.dupe(u8, new_path);
        }

        if (self.process_registry) |registry| {
            for (registry.backends) |*backend| {
                try backend.prepareFileLockHandlePaths(self.allocator, &prepared, old_path, new_path);
            }
        } else {
            try self.prepareFileLockHandlePaths(self.allocator, &prepared, old_path, new_path);
        }

        return prepared;
    }

    fn prepareFileLockHandlePaths(
        self: *Backend,
        list_allocator: std.mem.Allocator,
        prepared: *FileLockRekey,
        old_path: []const u8,
        new_path: []const u8,
    ) std.mem.Allocator.Error!void {
        for (self.handles.items) |entry| {
            const file_state = switch (entry.state) {
                .file => |state| state,
                .listener, .connection => continue,
            };
            const lock_path = file_state.lock_path orelse continue;
            if (!std.mem.eql(u8, lock_path, old_path)) continue;
            const owned_path = try self.allocator.dupe(u8, new_path);
            var path_owned = true;
            errdefer if (path_owned) self.allocator.free(owned_path);
            try prepared.handle_paths.append(list_allocator, .{
                .backend = self,
                .state = file_state,
                .path = owned_path,
            });
            path_owned = false;
        }
    }

    pub fn commitFileLockRekey(
        self: *Backend,
        old_path: []const u8,
        prepared: *FileLockRekey,
    ) void {
        if (prepared.registry_path) |path| {
            self.fileLockRegistry().rekey(self.task_runtime, old_path, path);
            prepared.registry_path = null;
        }
        for (prepared.handle_paths.items) |entry| {
            const old_lock_path = entry.state.lock_path orelse unreachable;
            entry.backend.allocator.free(old_lock_path);
            entry.state.lock_path = entry.path;
        }
        prepared.handle_paths.clearRetainingCapacity();
    }

    fn retireFileWaitersAndPathOwners(self: *Backend, task_control: ?ProcessTaskControl) void {
        self.fileLockRegistry().retireWaiters(self);
        self.pathGate().retireInactive(self, task_control, self.task_runtime);
    }

    pub fn openDirectoryFileHandle(self: *Backend, path: []const u8) std.mem.Allocator.Error!Io.File {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const file_state = try self.allocator.create(FileState);
        errdefer self.allocator.destroy(file_state);
        file_state.* = .{
            .target = .{ .directory = owned_path },
            .read = true,
            .write = false,
        };

        const handle = try self.createHandle(.{ .file = file_state });
        return .{
            .handle = @intCast(handle),
            .flags = .{ .nonblocking = false },
        };
    }
};

pub const ProcessRegistry = struct {
    allocator: std.mem.Allocator,
    backends: []Backend = &.{},
    listeners: std.ArrayList(ListenerRegistration) = .empty,
    futex_keys: std.ArrayList(FutexKeyRegistration) = .empty,
    next_futex_key: usize = 1,
    next_group_id: usize = 1,
    next_handle: SocketHandle = 1000,
    next_ephemeral_port: u16 = Backend.ephemeral_port_min,
    locks: FileLockRegistry,
    path_gate: PathGate,

    const ListenerRegistration = struct {
        backend: *Backend,
        handle: SocketHandle,
        address: Io.net.IpAddress,
    };

    const FutexKeyRegistration = struct {
        backend: *Backend,
        address: usize,
        key: usize,
        waiters: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator) ProcessRegistry {
        return .{
            .allocator = allocator,
            .locks = .init(allocator),
            .path_gate = .init(allocator),
        };
    }

    pub fn deinit(self: *ProcessRegistry) void {
        self.futex_keys.deinit(self.allocator);
        self.listeners.deinit(self.allocator);
        self.locks.deinit();
        self.path_gate.deinit();
        self.* = undefined;
    }

    fn allocateHandle(self: *ProcessRegistry) SocketHandle {
        const handle = self.next_handle;
        self.next_handle += 1;
        return handle;
    }

    fn allocateGroupId(self: *ProcessRegistry) usize {
        const id = self.next_group_id;
        self.next_group_id += 1;
        return id;
    }

    fn registerListener(
        self: *ProcessRegistry,
        backend: *Backend,
        handle: SocketHandle,
        address: Io.net.IpAddress,
    ) std.mem.Allocator.Error!void {
        try self.listeners.append(self.allocator, .{
            .backend = backend,
            .handle = handle,
            .address = address,
        });
    }

    fn unregisterListener(self: *ProcessRegistry, backend: *Backend, handle: SocketHandle) void {
        for (self.listeners.items, 0..) |entry, index| {
            if (entry.backend == backend and entry.handle == handle) {
                _ = self.listeners.swapRemove(index);
                return;
            }
        }
    }

    fn findOpenListener(self: *ProcessRegistry, address: *const Io.net.IpAddress) ?Backend.ListenerRef {
        for (self.listeners.items) |entry| {
            if (!entry.address.eql(address)) continue;
            const listener = entry.backend.listener(entry.handle) orelse continue;
            if (listener.closed) continue;
            return .{
                .backend = entry.backend,
                .handle = entry.handle,
                .state = listener,
            };
        }
        return null;
    }

    fn findFutexKeyRegistration(self: *ProcessRegistry, backend: *Backend, address: usize) ?usize {
        for (self.futex_keys.items, 0..) |entry, index| {
            if (entry.backend == backend and entry.address == address) return index;
        }
        return null;
    }

    fn retireFutexKeyAt(self: *ProcessRegistry, index: usize) void {
        std.debug.assert(self.futex_keys.items[index].waiters == 0);
        _ = self.futex_keys.swapRemove(index);
    }

    fn beginFutexWait(self: *ProcessRegistry, backend: *Backend, ptr: *const u32) std.mem.Allocator.Error!usize {
        const address = @intFromPtr(ptr);
        // Pointer identity is scoped by backend/process. Address reuse after a
        // futex's lifetime gets a fresh key once all old waiters are gone.
        // While any waiter is blocked, the old stable logical key remains
        // registered and raw addresses stay out of deterministic traces.
        if (self.findFutexKeyRegistration(backend, address)) |index| {
            self.futex_keys.items[index].waiters += 1;
            return self.futex_keys.items[index].key;
        }

        const key = self.next_futex_key;
        self.next_futex_key += 1;
        try self.futex_keys.append(self.allocator, .{
            .backend = backend,
            .address = address,
            .key = key,
            .waiters = 1,
        });
        return key;
    }

    fn endFutexWait(self: *ProcessRegistry, backend: *Backend, ptr: *const u32) void {
        const address = @intFromPtr(ptr);
        const index = self.findFutexKeyRegistration(backend, address) orelse unreachable;
        std.debug.assert(self.futex_keys.items[index].waiters > 0);
        self.futex_keys.items[index].waiters -= 1;
        if (self.futex_keys.items[index].waiters == 0) self.retireFutexKeyAt(index);
    }

    fn futexWakeKey(self: *ProcessRegistry, backend: *Backend, ptr: *const u32) ?usize {
        const address = @intFromPtr(ptr);
        const index = self.findFutexKeyRegistration(backend, address) orelse return null;
        return self.futex_keys.items[index].key;
    }

    fn retireFutexKeysForBackend(self: *ProcessRegistry, backend: *Backend) void {
        var index: usize = 0;
        while (index < self.futex_keys.items.len) {
            if (self.futex_keys.items[index].backend == backend) {
                _ = self.futex_keys.swapRemove(index);
                continue;
            }
            index += 1;
        }
    }
};

pub const ProcessRuntime = struct {
    allocator: std.mem.Allocator,
    world: *World,
    disk: disk_module.Disk,
    sector_size: u64,
    registry: ProcessRegistry,
    backends: []Backend,
    task_control: ?ProcessTaskControl = null,

    pub fn init(
        self: *ProcessRuntime,
        allocator: std.mem.Allocator,
        world: *World,
        disk: disk_module.Disk,
        sector_size: u64,
        process_count: usize,
    ) std.mem.Allocator.Error!void {
        std.debug.assert(process_count > 0);
        std.debug.assert(process_count <= std.math.maxInt(ProcessId) + 1);

        const backends = try allocator.alloc(Backend, process_count);
        errdefer allocator.free(backends);

        self.* = .{
            .allocator = allocator,
            .world = world,
            .disk = disk,
            .sector_size = sector_size,
            .registry = .init(allocator),
            .backends = backends,
        };
        self.registry.backends = backends;

        for (self.backends, 0..) |*backend, index| {
            backend.* = Backend.init(allocator, world, disk, sector_size);
            backend.attachProcessRegistry(&self.registry, @intCast(index));
        }
    }

    pub fn deinit(self: *ProcessRuntime) void {
        for (self.backends) |*backend| backend.task_runtime = null;
        for (self.backends) |*backend| backend.deinit();
        self.allocator.free(self.backends);
        self.registry.deinit();
        self.* = undefined;
    }

    pub fn backendForNode(self: *ProcessRuntime, node: network_module.NodeId) error{InvalidNode}!*Backend {
        if (@as(usize, node) >= self.backends.len) return error.InvalidNode;
        return &self.backends[node];
    }

    pub fn io(self: *ProcessRuntime, node: network_module.NodeId) error{ InvalidNode, ProcessKilled }!Io {
        const backend = try self.backendForNode(node);
        if (!backend.processIsAlive()) return error.ProcessKilled;
        return backend.io();
    }

    pub fn revive(self: *ProcessRuntime, node: network_module.NodeId) error{InvalidNode}!void {
        const backend = try self.backendForNode(node);
        backend.process_alive = true;
    }

    pub fn processCount(self: *const ProcessRuntime) usize {
        return self.backends.len;
    }

    pub fn attachNetworkControl(self: *ProcessRuntime, control: network_module.AnyNetworkControl) void {
        for (self.backends) |*backend| backend.attachNetworkControl(control);
    }

    pub fn attachFutexWaitSet(self: *ProcessRuntime, wait_set: FutexWaitSet) void {
        for (self.backends) |*backend| backend.attachFutexWaitSet(wait_set);
    }

    pub fn attachTaskRuntime(self: *ProcessRuntime, runtime: TaskRuntime) void {
        for (self.backends, 0..) |*backend, index| {
            var process_runtime = runtime;
            process_runtime.process_id = @intCast(index);
            backend.attachTaskRuntime(process_runtime);
        }
    }

    pub fn attachProcessTaskControl(self: *ProcessRuntime, control: ProcessTaskControl) void {
        self.task_control = control;
    }

    pub fn onDiskCrash(self: *ProcessRuntime) void {
        for (self.backends, 0..) |*backend, index| {
            backend.onDiskCrash();
            self.killProcessTasks(@intCast(index));
            retireKilledGroupClosures(backend, self.task_control);
            backend.retireFileWaitersAndPathOwners(self.task_control);
            backend.retireFutexKeysForBackend();
            backend.retireClosedNetHandlesAfterTaskKill();
        }
        self.sweepInactiveOpScratch();
    }

    pub fn kill(self: *ProcessRuntime, node: network_module.NodeId) error{InvalidNode}!void {
        const backend = try self.backendForNode(node);
        backend.killProcess(.{ .invalidate_files = true });
        self.killProcessTasks(@intCast(node));
        retireKilledGroupClosures(backend, self.task_control);
        backend.retireFileWaitersAndPathOwners(self.task_control);
        self.sweepInactiveOpScratch();
        backend.retireFutexKeysForBackend();
        backend.retireClosedNetHandlesAfterTaskKill();
    }

    fn sweepInactiveOpScratch(self: *ProcessRuntime) void {
        for (self.backends) |*backend| backend.sweepInactiveOpScratch(self.task_control);
    }

    fn killProcessTasks(self: *ProcessRuntime, process_id: ProcessId) void {
        if (self.task_control) |control| control.killProcess(process_id);
    }
};

const file_ops = file_module.Ops(Backend);
const futex_ops = futex_module.Ops(Backend);
const net_ops = net_module.Ops(Backend);

pub fn deinitBackendOpaque(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const backend: *Backend = @ptrCast(@alignCast(ptr));
    backend.deinit();
    allocator.destroy(backend);
}

pub fn onDiskCrashOpaque(ptr: *anyopaque) void {
    const backend: *Backend = @ptrCast(@alignCast(ptr));
    backend.onDiskCrash();
}

pub fn deinitProcessRuntimeOpaque(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const runtime: *ProcessRuntime = @ptrCast(@alignCast(ptr));
    runtime.deinit();
    allocator.destroy(runtime);
}

pub fn onProcessRuntimeDiskCrashOpaque(ptr: *anyopaque) void {
    const runtime: *ProcessRuntime = @ptrCast(@alignCast(ptr));
    runtime.onDiskCrash();
}

const sim_vtable: Io.VTable = .{
    .crashHandler = Io.noCrashHandler,

    .async = simAsync,
    .concurrent = simConcurrent,
    .await = simAwait,
    .cancel = simCancel,

    .groupAsync = simGroupAsync,
    .groupConcurrent = simGroupConcurrent,
    .groupAwait = simGroupAwait,
    .groupCancel = simGroupCancel,

    .recancel = simRecancel,
    .swapCancelProtection = simSwapCancelProtection,
    .checkCancel = simCheckCancel,

    .futexWait = futex_ops.simFutexWait,
    .futexWaitUncancelable = futex_ops.simFutexWaitUncancelable,
    .futexWake = futex_ops.simFutexWake,

    .operate = simOperate,
    .batchAwaitAsync = Io.unreachableBatchAwaitAsync,
    .batchAwaitConcurrent = Io.unreachableBatchAwaitConcurrent,
    .batchCancel = Io.unreachableBatchCancel,

    .dirCreateDir = file_ops.simDirCreateDir,
    .dirCreateDirPath = file_ops.simDirCreateDirPath,
    .dirCreateDirPathOpen = file_ops.simDirCreateDirPathOpen,
    .dirOpenDir = file_ops.simDirOpenDir,
    .dirStat = file_ops.simDirStat,
    .dirStatFile = file_ops.simDirStatFile,
    .dirAccess = file_ops.simDirAccess,
    .dirCreateFile = file_ops.simDirCreateFile,
    .dirCreateFileAtomic = Io.failingDirCreateFileAtomic,
    .dirOpenFile = file_ops.simDirOpenFile,
    .dirClose = file_ops.simDirClose,
    .dirRead = file_ops.simDirRead,
    .dirRealPath = Io.failingDirRealPath,
    .dirRealPathFile = Io.failingDirRealPathFile,
    .dirDeleteFile = file_ops.simDirDeleteFile,
    .dirDeleteDir = Io.failingDirDeleteDir,
    .dirRename = file_ops.simDirRename,
    .dirRenamePreserve = Io.failingDirRenamePreserve,
    .dirSymLink = Io.failingDirSymLink,
    .dirReadLink = Io.failingDirReadLink,
    .dirSetOwner = Io.failingDirSetOwner,
    .dirSetFileOwner = Io.failingDirSetFileOwner,
    .dirSetPermissions = Io.failingDirSetPermissions,
    .dirSetFilePermissions = Io.failingDirSetFilePermissions,
    .dirSetTimestamps = Io.noDirSetTimestamps,
    .dirHardLink = Io.failingDirHardLink,

    .fileStat = file_ops.simFileStat,
    .fileLength = file_ops.simFileLength,
    .fileClose = file_ops.simFileClose,
    .fileWritePositional = file_ops.simFileWritePositional,
    .fileWriteFileStreaming = Io.noFileWriteFileStreaming,
    .fileWriteFilePositional = Io.noFileWriteFilePositional,
    .fileReadPositional = file_ops.simFileReadPositional,
    .fileSeekBy = file_ops.simFileSeekBy,
    .fileSeekTo = file_ops.simFileSeekTo,
    .fileSync = file_ops.simFileSync,
    .fileIsTty = Io.unreachableFileIsTty,
    .fileEnableAnsiEscapeCodes = Io.unreachableFileEnableAnsiEscapeCodes,
    .fileSupportsAnsiEscapeCodes = Io.unreachableFileSupportsAnsiEscapeCodes,
    .fileSetLength = file_ops.simFileSetLength,
    .fileSetOwner = Io.failingFileSetOwner,
    .fileSetPermissions = Io.failingFileSetPermissions,
    .fileSetTimestamps = Io.noFileSetTimestamps,
    .fileLock = Io.failingFileLock,
    .fileTryLock = Io.failingFileTryLock,
    .fileUnlock = Io.unreachableFileUnlock,
    .fileDowngradeLock = Io.failingFileDowngradeLock,
    .fileRealPath = Io.failingFileRealPath,
    .fileHardLink = Io.failingFileHardLink,

    .fileMemoryMapCreate = Io.failingFileMemoryMapCreate,
    .fileMemoryMapDestroy = Io.unreachableFileMemoryMapDestroy,
    .fileMemoryMapSetLength = Io.unreachableFileMemoryMapSetLength,
    .fileMemoryMapRead = Io.unreachableFileMemoryMapRead,
    .fileMemoryMapWrite = Io.unreachableFileMemoryMapWrite,

    .processExecutableOpen = Io.failingProcessExecutableOpen,
    .processExecutablePath = Io.failingProcessExecutablePath,
    .lockStderr = Io.unreachableLockStderr,
    .tryLockStderr = Io.noTryLockStderr,
    .unlockStderr = Io.unreachableUnlockStderr,
    .processCurrentPath = Io.failingProcessCurrentPath,
    .processSetCurrentDir = Io.failingProcessSetCurrentDir,
    .processSetCurrentPath = Io.failingProcessSetCurrentPath,
    .processReplace = Io.failingProcessReplace,
    .processReplacePath = Io.failingProcessReplacePath,
    .processSpawn = Io.failingProcessSpawn,
    .processSpawnPath = Io.failingProcessSpawnPath,
    .childWait = Io.unreachableChildWait,
    .childKill = Io.unreachableChildKill,

    .progressParentFile = Io.failingProgressParentFile,

    .random = simRandom,
    .randomSecure = simRandomSecure,

    .now = simNow,
    .clockResolution = simClockResolution,
    .sleep = simSleep,

    .netListenIp = net_ops.simNetListenIp,
    .netAccept = net_ops.simNetAccept,
    .netBindIp = Io.failingNetBindIp,
    .netConnectIp = net_ops.simNetConnectIp,
    .netListenUnix = Io.failingNetListenUnix,
    .netConnectUnix = Io.failingNetConnectUnix,
    .netSocketCreatePair = Io.failingNetSocketCreatePair,
    .netSend = Io.failingNetSend,
    .netRead = net_ops.simNetRead,
    .netWrite = net_ops.simNetWrite,
    .netWriteFile = Io.failingNetWriteFile,
    .netClose = net_ops.simNetClose,
    .netShutdown = net_ops.simNetShutdown,
    .netInterfaceNameResolve = Io.failingNetInterfaceNameResolve,
    .netInterfaceName = Io.unreachableNetInterfaceName,
    .netLookup = net_ops.simNetLookup,
};

fn backendFromUserdata(userdata: ?*anyopaque) *Backend {
    return @ptrCast(@alignCast(userdata.?));
}

fn worldFromUserdata(userdata: ?*anyopaque) *World {
    return backendFromUserdata(userdata).world;
}

fn supportsClock(clock: Io.Clock) bool {
    return switch (clock) {
        .real, .awake, .boot => true,
        .cpu_process, .cpu_thread => false,
    };
}

/// Heap record backing one spawned `Io.async`/`Io.concurrent` task.
///
/// Context and result are stored out-of-line because the caller's context
/// buffer expires when the vtable call returns, while the result must
/// survive until `await`/`cancel` collects it.
const AlignedStorage = struct {
    bytes: []u8,
    alignment: std.mem.Alignment,

    fn create(
        allocator: std.mem.Allocator,
        len: usize,
        alignment: std.mem.Alignment,
    ) error{OutOfMemory}!AlignedStorage {
        if (len == 0) {
            const address = alignment.backward(std.math.maxInt(usize));
            return .{
                .bytes = @as([*]u8, @ptrFromInt(address))[0..0],
                .alignment = alignment,
            };
        }
        const ptr = allocator.rawAlloc(len, alignment, @returnAddress()) orelse
            return error.OutOfMemory;
        return .{ .bytes = ptr[0..len], .alignment = alignment };
    }

    fn destroy(self: AlignedStorage, allocator: std.mem.Allocator) void {
        if (self.bytes.len == 0) return;
        allocator.rawFree(self.bytes, self.alignment, @returnAddress());
    }
};

const GroupState = struct {
    backend: *Backend,
    group: *Io.Group,
    id: usize,
    pending: usize = 0,
    done: bool = false,

    fn completionKey(self: *const GroupState) usize {
        return futex_module.waitKey(.group, self.id);
    }

    fn addTask(self: *GroupState) void {
        self.pending += 1;
        self.done = false;
    }

    fn completeTask(self: *GroupState) void {
        std.debug.assert(self.pending > 0);
        self.pending -= 1;
        if (self.pending != 0) return;
        self.done = true;
        if (self.backend.task_runtime) |runtime| {
            _ = runtime.wake(self.completionKey(), std.math.maxInt(usize));
        }
    }
};

const GroupClosure = struct {
    backend: *Backend,
    state: ?*GroupState,
    task_id: u64 = std.math.maxInt(u64),
    start: *const fn (context: *const anyopaque) void,
    context: AlignedStorage,

    fn create(
        backend: *Backend,
        state: *GroupState,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) void,
    ) error{OutOfMemory}!*GroupClosure {
        const closure = try backend.allocator.create(GroupClosure);
        errdefer backend.allocator.destroy(closure);
        const context_copy = try AlignedStorage.create(
            backend.allocator,
            context.len,
            context_alignment,
        );
        errdefer context_copy.destroy(backend.allocator);
        @memcpy(context_copy.bytes, context);
        closure.* = .{
            .backend = backend,
            .state = state,
            .start = start,
            .context = context_copy,
        };
        return closure;
    }

    fn destroy(self: *GroupClosure, allocator: std.mem.Allocator) void {
        self.context.destroy(allocator);
        allocator.destroy(self);
    }

    fn cancelForKill(self: *GroupClosure) void {
        const state = self.state orelse return;
        self.state = null;
        state.completeTask();
    }

    fn run(raw: *anyopaque) void {
        const closure: *GroupClosure = @ptrCast(@alignCast(raw));
        closure.start(closure.context.bytes.ptr);
        if (closure.state) |state| state.completeTask();
        closure.state = null;
        releaseGroupClosure(closure);
    }
};

const AsyncClosure = struct {
    backend: *Backend,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    task_id: u64 = 0,
    done: bool = false,
    context: AlignedStorage,
    result: AlignedStorage,

    fn create(
        backend: *Backend,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) error{OutOfMemory}!*AsyncClosure {
        const closure = try backend.allocator.create(AsyncClosure);
        errdefer backend.allocator.destroy(closure);
        const context_copy = try AlignedStorage.create(backend.allocator, context.len, context_alignment);
        errdefer context_copy.destroy(backend.allocator);
        const result = try AlignedStorage.create(backend.allocator, result_len, result_alignment);
        errdefer result.destroy(backend.allocator);

        @memcpy(context_copy.bytes, context);
        closure.* = .{
            .backend = backend,
            .start = start,
            .context = context_copy,
            .result = result,
        };
        return closure;
    }

    fn destroy(self: *AsyncClosure, allocator: std.mem.Allocator) void {
        self.context.destroy(allocator);
        self.result.destroy(allocator);
        allocator.destroy(self);
    }

    fn completionKey(self: *const AsyncClosure) usize {
        return futex_module.waitKey(.task, @intCast(self.task_id));
    }

    /// Publish cancellation completion for a future whose task was killed.
    ///
    /// `std.Io`'s single-future ABI has no cancellation error channel here, so
    /// the least surprising simulator behavior is to unblock awaiters with a
    /// zeroed result after the owning process has been killed.
    fn cancelForKill(self: *AsyncClosure) void {
        if (self.done) return;
        @memset(self.result.bytes, 0);
        self.done = true;
        if (self.backend.task_runtime) |runtime| {
            _ = runtime.wake(self.completionKey(), std.math.maxInt(usize));
        }
    }

    /// Task entry: run the user function, then publish completion.
    fn run(raw: *anyopaque) void {
        const closure: *AsyncClosure = @ptrCast(@alignCast(raw));
        closure.start(closure.context.bytes.ptr, closure.result.bytes.ptr);
        closure.done = true;
        const runtime = closure.backend.task_runtime orelse unreachable;
        _ = runtime.wake(closure.completionKey(), std.math.maxInt(usize));
    }
};

fn simAsync(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Io.AnyFuture {
    const backend = backendFromUserdata(userdata);
    if (!backend.processIsAlive()) {
        @memset(result, 0);
        return null;
    }
    return simConcurrent(userdata, result.len, result_alignment, context, context_alignment, start) catch {
        // No task runtime attached: run eagerly on the caller, preserving
        // `async` semantics (concurrency is optional for it).
        start(context.ptr, result.ptr);
        return null;
    };
}

const AcquiredGroupState = struct {
    state: *GroupState,
    created: bool,
};

fn acquireGroupState(backend: *Backend, group: *Io.Group) error{OutOfMemory}!AcquiredGroupState {
    if (group.token.load(.acquire)) |token| {
        return .{ .state = @ptrCast(@alignCast(token)), .created = false };
    }

    const state = try backend.allocator.create(GroupState);
    errdefer backend.allocator.destroy(state);
    state.* = .{
        .backend = backend,
        .group = group,
        .id = backend.allocateGroupId(),
    };
    try backend.group_states.append(backend.allocator, state);
    errdefer _ = backend.group_states.pop();

    if (group.token.cmpxchgStrong(null, @ptrCast(state), .acq_rel, .acquire)) |token| {
        _ = backend.group_states.pop();
        backend.allocator.destroy(state);
        return .{ .state = @ptrCast(@alignCast(token)), .created = false };
    }
    return .{ .state = state, .created = true };
}

fn releaseGroupState(state: *GroupState) void {
    const backend = state.backend;
    state.group.token.store(null, .release);
    for (backend.group_states.items, 0..) |candidate, index| {
        if (candidate == state) {
            _ = backend.group_states.swapRemove(index);
            break;
        }
    }
    backend.allocator.destroy(state);
}

fn rollbackGroupSpawn(acquired: AcquiredGroupState) void {
    acquired.state.completeTask();
    if (acquired.created) releaseGroupState(acquired.state);
}

fn spawnGroupTask(
    backend: *Backend,
    group: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) Io.ConcurrentError!void {
    if (!backend.processIsAlive()) return error.ConcurrencyUnavailable;
    const runtime = backend.task_runtime orelse return error.ConcurrencyUnavailable;
    const acquired = acquireGroupState(backend, group) catch return error.ConcurrencyUnavailable;
    acquired.state.addTask();
    errdefer rollbackGroupSpawn(acquired);

    const closure = GroupClosure.create(
        backend,
        acquired.state,
        context,
        context_alignment,
        start,
    ) catch return error.ConcurrencyUnavailable;
    errdefer closure.destroy(backend.allocator);

    backend.group_closures.append(backend.allocator, closure) catch
        return error.ConcurrencyUnavailable;
    errdefer _ = backend.group_closures.pop();

    closure.task_id = try runtime.spawn(GroupClosure.run, closure);
}

fn simGroupAsync(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    const backend = backendFromUserdata(userdata);
    if (!backend.processIsAlive()) return;
    spawnGroupTask(backend, group, context, context_alignment, start) catch {
        start(context.ptr);
    };
}

fn simGroupConcurrent(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) Io.ConcurrentError!void {
    try spawnGroupTask(
        backendFromUserdata(userdata),
        group,
        context,
        context_alignment,
        start,
    );
}

fn simGroupAwait(
    userdata: ?*anyopaque,
    group: *Io.Group,
    token: *anyopaque,
) Io.Cancelable!void {
    const backend = backendFromUserdata(userdata);
    const state: *GroupState = @ptrCast(@alignCast(token));
    std.debug.assert(state.backend == backend);
    std.debug.assert(state.group == group);
    const runtime = backend.task_runtime orelse unreachable;
    var canceled = false;

    if (!state.done) {
        if (runtime.inTask()) {
            const wait_set = backend.futex_wait_set orelse unreachable;
            while (!state.done) {
                if (canceled) {
                    runtime.block(state.completionKey());
                    continue;
                }
                switch (wait_set.blockUntilCancelable(state.completionKey(), null)) {
                    .woken => {},
                    .timed_out => unreachable,
                    .canceled => {
                        canceled = true;
                        requestGroupCancel(backend, state);
                    },
                }
            }
        } else {
            runtime.runUntilDone(&state.done);
        }
    }
    releaseGroupState(state);
    if (canceled) return error.Canceled;
}

fn simGroupCancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
    const backend = backendFromUserdata(userdata);
    const state: *GroupState = @ptrCast(@alignCast(token));
    std.debug.assert(state.backend == backend);
    std.debug.assert(state.group == group);

    if (!state.done) requestGroupCancel(backend, state);
    // The group-await park is not itself a cancellation point, so this cannot
    // surface `error.Canceled`.
    simGroupAwait(userdata, group, token) catch unreachable;
}

/// Arm cancellation requests on every live member of `state`, in ascending
/// task order so delivery is deterministic regardless of spawn interleaving.
fn requestGroupCancel(backend: *Backend, state: *GroupState) void {
    const runtime = backend.task_runtime orelse return;

    var member_ids: std.ArrayList(u64) = .empty;
    defer member_ids.deinit(backend.allocator);
    for (backend.group_closures.items) |closure| {
        if (closure.state == state) {
            member_ids.append(backend.allocator, closure.task_id) catch
                @panic("failed to collect group members for cancellation");
        }
    }
    std.mem.sort(u64, member_ids.items, {}, std.sort.asc(u64));
    for (member_ids.items) |task_id| runtime.requestCancel(task_id);
}

fn simConcurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*Io.AnyFuture {
    const backend = backendFromUserdata(userdata);
    if (!backend.processIsAlive()) return error.ConcurrencyUnavailable;
    const runtime = backend.task_runtime orelse return error.ConcurrencyUnavailable;

    const closure = AsyncClosure.create(
        backend,
        result_len,
        result_alignment,
        context,
        context_alignment,
        start,
    ) catch return error.ConcurrencyUnavailable;
    errdefer closure.destroy(backend.allocator);

    backend.async_closures.append(backend.allocator, closure) catch return error.ConcurrencyUnavailable;
    errdefer _ = backend.async_closures.pop();

    // A cooperative task is a unit of concurrency in the deterministic
    // simulation: it makes progress whenever the caller suspends, which is
    // what `concurrent` requires of single-threaded executors.
    closure.task_id = try runtime.spawn(AsyncClosure.run, closure);
    return @ptrCast(closure);
}

fn simAwait(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    _ = result_alignment;
    _ = backendFromUserdata(userdata);
    const closure: *AsyncClosure = @ptrCast(@alignCast(any_future));
    // `await` is only called when `async` returned non-null, so a runtime
    // was attached at spawn time.
    const runtime = closure.backend.task_runtime orelse unreachable;

    if (!closure.done) {
        if (runtime.inTask()) {
            while (!closure.done) runtime.block(closure.completionKey());
        } else {
            runtime.runUntilDone(&closure.done);
        }
    }

    @memcpy(result, closure.result.bytes[0..result.len]);
    releaseClosure(closure);
}

fn simCancel(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    const closure: *AsyncClosure = @ptrCast(@alignCast(any_future));
    if (!closure.done) {
        // The awaited task receives `error.Canceled` at its next cancellation
        // point; cooperative tasks cannot be preempted mid-run, so a task
        // that never reaches one runs to completion.
        const runtime = closure.backend.task_runtime orelse unreachable;
        runtime.requestCancel(closure.task_id);
    }
    simAwait(userdata, any_future, result, result_alignment);
}

fn releaseClosure(closure: *AsyncClosure) void {
    const backend = closure.backend;
    for (backend.async_closures.items, 0..) |candidate, index| {
        if (candidate == closure) {
            _ = backend.async_closures.swapRemove(index);
            break;
        }
    }
    closure.destroy(backend.allocator);
}

fn releaseGroupClosure(closure: *GroupClosure) void {
    const backend = closure.backend;
    for (backend.group_closures.items, 0..) |candidate, index| {
        if (candidate == closure) {
            _ = backend.group_closures.swapRemove(index);
            break;
        }
    }
    closure.destroy(backend.allocator);
}

fn retireKilledGroupClosures(
    self: *Backend,
    task_control: ?ProcessTaskControl,
) void {
    var index: usize = 0;
    while (index < self.group_closures.items.len) {
        const closure = self.group_closures.items[index];
        if (closure.state != null) {
            index += 1;
            continue;
        }
        if (task_control) |control| {
            if (control.taskActive(closure.task_id)) {
                index += 1;
                continue;
            }
        }
        _ = self.group_closures.swapRemove(index);
        closure.destroy(self.allocator);
    }
}

fn simRandom(userdata: ?*anyopaque, buffer: []u8) void {
    const world = worldFromUserdata(userdata);
    world.unsafeUntracedRandom().bytes(buffer);

    // Trace the draw so replay divergence is visible at the draw site. The
    // digest stands in for the bytes: byte-identical draws produce
    // byte-identical trace lines without inflating traces by buffer size.
    // Wyhash with a fixed seed is deterministic across runs and platforms.
    const digest = std.hash.Wyhash.hash(0, buffer);
    world.recordFields("io.random", &.{
        traceField("len", .{ .uint = @intCast(buffer.len) }),
        traceField("digest", .{ .uint = digest }),
    }) catch @panic("failed to record simulated io random");
}

fn simRandomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    simRandom(userdata, buffer);
}

fn simRecancel(userdata: ?*anyopaque) void {
    const backend = backendFromUserdata(userdata);
    // Without a scheduler there are no cancelable tasks, so cancellation
    // checks stay inert instead of asserting.
    const runtime = backend.task_runtime orelse return;
    runtime.recancel();
}

fn simSwapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    const backend = backendFromUserdata(userdata);
    const runtime = backend.task_runtime orelse return .unblocked;
    return runtime.swapCancelProtection(new);
}

fn simCheckCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    const backend = backendFromUserdata(userdata);
    const runtime = backend.task_runtime orelse return;
    if (runtime.takeCancelRequest()) return error.Canceled;
}

fn simOperate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    return switch (operation) {
        .file_read_streaming => |read| .{
            .file_read_streaming = file_ops.simFileReadStreaming(userdata, read.file, read.data),
        },
        .file_write_streaming => |write| .{
            .file_write_streaming = file_ops.simFileWriteStreaming(userdata, write.file, write.header, write.data, write.splat),
        },
        .device_io_control => unreachable,
        .net_receive => .{ .net_receive = .{ error.NetworkDown, 0 } },
    };
}

fn simNow(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    if (!supportsClock(clock)) return .zero;
    return .fromNanoseconds(@intCast(worldFromUserdata(userdata).now()));
}

fn simClockResolution(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    if (!supportsClock(clock)) return error.ClockUnavailable;
    const world = worldFromUserdata(userdata);
    return .fromNanoseconds(@intCast(world.clock().tick_ns));
}

fn simSleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const backend = backendFromUserdata(userdata);
    if (!backend.processIsAlive()) return error.Canceled;
    // A cancellation point delivers an armed request even for zero-length
    // sleeps that would return without parking.
    if (backend.task_runtime) |runtime| {
        if (runtime.takeCancelRequest()) return error.Canceled;
    }
    const world = backend.world;
    const deadline_ns = switch (timeout) {
        .none => return,
        .duration => |duration| b: {
            if (!supportsClock(duration.clock)) return;
            if (duration.raw.nanoseconds <= 0) return;
            const delta = std.math.cast(u64, duration.raw.nanoseconds) orelse
                @panic("simulated sleep duration exceeds clock range");
            break :b std.math.add(u64, world.now(), delta) catch
                @panic("simulated sleep deadline exceeds clock range");
        },
        .deadline => |deadline| b: {
            if (!supportsClock(deadline.clock)) return;
            const deadline_ns = std.math.cast(u64, deadline.raw.nanoseconds) orelse return;
            if (deadline_ns <= world.now()) return;
            break :b deadline_ns;
        },
    };

    if (backend.futex_wait_set) |wait_set| {
        // All sleepers share one wait key, so a wake on that key (nothing
        // issues one today) must not end a sleep early. Re-park until the
        // deadline has actually passed; the scheduler returns `timed_out`
        // immediately once it has.
        while (world.now() < deadline_ns) {
            switch (wait_set.blockUntilCancelable(backend.sleepWaitKey(), deadline_ns)) {
                .woken => {},
                .timed_out => {},
                .canceled => return error.Canceled,
            }
        }
        return;
    }

    const duration_ns = world.clock().ceilDuration(deadline_ns - world.now());
    world.runFor(duration_ns) catch @panic("failed to record simulated sleep");
}
