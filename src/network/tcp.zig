//! TCP-lite over a push-based packet fabric (`semantics = .tcp_v1`).
//!
//! Hosts own addresses, port tables, and ephemeral ranges. Every socket's
//! state lives in its own host's table; endpoints interact only through
//! segments carried by the fabric. Segments are delivered at their arrival
//! time whether or not anyone reads, into bounded per-socket buffers, so one
//! stalled connection cannot starve another.
//!
//! A fault by itself produces silence. Errors come only from mechanisms with
//! Linux-shaped timing: an RST for a closed port or a reset connection,
//! retransmission exhaustion, an ARP failure for an absent host, or an
//! explicit `reject` fault's unreachable signal.
//!
//! Every engine entry point processes due events before it returns, so no
//! event is ever due at the current time once control leaves the engine.

const std = @import("std");

const clock_module = @import("../clock.zig");
const faults_module = @import("faults.zig");
const types = @import("types.zig");
const World = @import("../world.zig").World;

const Io = std.Io;
const IpAddress = Io.net.IpAddress;
const NodeId = types.NodeId;
const Timestamp = clock_module.Timestamp;
const Duration = clock_module.Duration;

const ms = std.time.ns_per_ms;
const s = std.time.ns_per_s;

/// Linux-shaped timer constants. `.compressed` divides every interval by 100
/// so long-horizon behavior (SYN retries, retransmission exhaustion) runs
/// cheaply; each interval is still rounded up to the world tick.
pub const Timing = struct {
    syn_rto_ns: Duration,
    min_rto_ns: Duration,
    max_rto_ns: Duration,
    delayed_ack_ns: Duration,
    fin_wait2_ns: Duration,
    time_wait_ns: Duration,
    arp_failure_ns: Duration,
    /// SYN retransmissions before `connect` times out (`tcp_syn_retries`).
    syn_retries: u8 = 6,
    /// SYN-ACK retransmissions before a half-open connection is dropped.
    synack_retries: u8 = 5,
    /// Data retransmissions before an established connection times out
    /// (`tcp_retries2`).
    data_retries: u8 = 15,

    pub const linux: Timing = .{
        .syn_rto_ns = 1 * s,
        .min_rto_ns = 200 * ms,
        .max_rto_ns = 120 * s,
        .delayed_ack_ns = 40 * ms,
        .fin_wait2_ns = 60 * s,
        .time_wait_ns = 60 * s,
        .arp_failure_ns = 3 * s,
    };

    pub const compressed: Timing = .{
        .syn_rto_ns = 10 * ms,
        .min_rto_ns = 2 * ms,
        .max_rto_ns = 1200 * ms,
        .delayed_ack_ns = 400 * std.time.ns_per_us,
        .fin_wait2_ns = 600 * ms,
        .time_wait_ns = 600 * ms,
        .arp_failure_ns = 30 * ms,
    };

    pub fn forProfile(profile: types.TimingProfile) Timing {
        return switch (profile) {
            .linux => linux,
            .compressed => compressed,
        };
    }
};

pub const SocketError = enum {
    refused,
    reset,
    timed_out,
    host_unreachable,
    network_unreachable,
    network_down,
};

pub const State = enum {
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    closing,
    time_wait,
    close_wait,
    last_ack,
    closed,

    fn label(self: State) []const u8 {
        return switch (self) {
            .syn_sent => "SYN_SENT",
            .syn_received => "SYN_RECV",
            .established => "ESTABLISHED",
            .fin_wait_1 => "FIN_WAIT1",
            .fin_wait_2 => "FIN_WAIT2",
            .closing => "CLOSING",
            .time_wait => "TIME_WAIT",
            .close_wait => "CLOSE_WAIT",
            .last_ack => "LAST_ACK",
            .closed => "CLOSED",
        };
    }
};

const Flags = struct {
    syn: bool = false,
    ack: bool = false,
    fin: bool = false,
    rst: bool = false,

    fn label(self: Flags, buffer: *[12]u8) []const u8 {
        var len: usize = 0;
        inline for (.{ .{ self.syn, "S" }, .{ self.fin, "F" }, .{ self.rst, "R" }, .{ self.ack, "A" } }) |entry| {
            if (entry[0]) {
                buffer[len] = entry[1][0];
                len += 1;
            }
        }
        if (len == 0) {
            buffer[0] = '-';
            len = 1;
        }
        return buffer[0..len];
    }
};

const Segment = struct {
    id: u64,
    from: NodeId,
    to: NodeId,
    src: IpAddress,
    dst: IpAddress,
    flags: Flags,
    seq: u64,
    ack: u64,
    wnd: u64,
    payload: []u8,

    fn seqLen(self: *const Segment) u64 {
        return self.payload.len + @intFromBool(self.flags.syn) + @intFromBool(self.flags.fin);
    }
};

const TimerKind = enum(u3) {
    rto,
    delayed_ack,
    persist,
    fin_wait2,
    time_wait,
    arp,
};
const timer_kind_count = @typeInfo(TimerKind).@"enum".field_names.len;

const Event = struct {
    at: Timestamp,
    seq: u64,
    kind: Kind,

    const Kind = union(enum) {
        segment: *Segment,
        icmp: Icmp,
        timer: Timer,
    };

    const Timer = struct {
        conn: u64,
        kind: TimerKind,
        generation: u64,
    };

    fn order(_: void, a: Event, b: Event) std.math.Order {
        if (a.at != b.at) return std.math.order(a.at, b.at);
        return std.math.order(a.seq, b.seq);
    }
};

const Icmp = struct {
    /// Packet that the fault refused.
    packet: u64,
    to: NodeId,
    /// Original sender's address and the address it tried to reach.
    src: IpAddress,
    dst: IpAddress,
    fault: u64,
};

const OutOfOrder = struct {
    seq: u64,
    bytes: []u8,
    fin: bool,
};

pub const Connection = struct {
    id: u64,
    host: NodeId,
    peer_host: NodeId,
    local: IpAddress,
    remote: IpAddress,
    state: State,
    /// Listener that owns this connection until it is accepted.
    listener: ?u64 = null,
    /// Application socket handle, when an application holds this socket.
    handle: ?u64 = null,
    /// The application closed this socket; the kernel finishes it alone.
    orphan: bool = false,

    // Send side. Sequence 0 is the SYN; data starts at 1.
    snd_una: u64 = 0,
    snd_nxt: u64 = 0,
    snd_wnd: u64 = 0,
    /// Unacknowledged and unsent bytes, starting at `send_seq`.
    send_buf: std.ArrayList(u8) = .empty,
    send_seq: u64 = 1,
    send_capacity: usize,
    fin_queued: bool = false,
    fin_sent: bool = false,
    fin_seq: u64 = 0,
    /// Highest sequence outstanding when loss recovery began.
    recover: u64 = 0,
    dupacks: u8 = 0,
    retries: u8 = 0,
    persist_probes: u8 = 0,
    rto_ns: Duration,
    srtt_ns: ?Duration = null,
    rttvar_ns: Duration = 0,
    rtt_sample: ?RttSample = null,
    persist_backoff_ns: Duration = 0,

    // Receive side.
    rcv_nxt: u64 = 0,
    recv_buf: std.ArrayList(u8) = .empty,
    recv_capacity: usize,
    out_of_order: std.ArrayList(OutOfOrder) = .empty,
    fin_received: bool = false,
    read_shutdown: bool = false,
    ack_pending: u8 = 0,
    last_advertised: u64 = 0,

    /// Pending socket error (`SO_ERROR`).
    err: ?SocketError = null,
    /// The error that closed the connection; writes keep reporting it.
    terminal: ?SocketError = null,
    /// Soft error from an unreachable signal; reported if retries run out.
    soft_err: ?SocketError = null,

    timer_generation: [timer_kind_count]u64 = @splat(0),
    timer_armed: [timer_kind_count]bool = @splat(false),

    const RttSample = struct {
        /// Sequence just past the timed segment.
        seq: u64,
        sent_at: Timestamp,
    };

    fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        self.send_buf.deinit(allocator);
        self.recv_buf.deinit(allocator);
        for (self.out_of_order.items) |entry| allocator.free(entry.bytes);
        self.out_of_order.deinit(allocator);
    }

    fn oooBytes(self: *const Connection) usize {
        var total: usize = 0;
        for (self.out_of_order.items) |entry| total += entry.bytes.len;
        return total;
    }

    fn window(self: *const Connection) u64 {
        const used = self.recv_buf.items.len + self.oooBytes();
        return self.recv_capacity -| used;
    }

    fn sendEnd(self: *const Connection) u64 {
        return self.send_seq + self.send_buf.items.len;
    }

    fn unsent(self: *const Connection) bool {
        return self.snd_nxt < self.sendEnd() or (self.fin_queued and !self.fin_sent);
    }

    fn inFlight(self: *const Connection) bool {
        return self.snd_una < self.snd_nxt;
    }
};

pub const Listener = struct {
    id: u64,
    host: NodeId,
    address: IpAddress,
    backlog: u31,
    handle: u64,
    /// Established connections waiting for `accept`, oldest first.
    accept_queue: std.ArrayList(u64) = .empty,
    closed: bool = false,
};

pub const ReadResult = union(enum) {
    bytes: usize,
    end_of_stream,
    would_block,
    failed: SocketError,
    not_connected,
};

pub const WriteResult = union(enum) {
    accepted: usize,
    would_block,
    failed: SocketError,
    not_connected,
};

pub const ConnectStatus = union(enum) {
    pending,
    established,
    failed: SocketError,
};

pub const AcceptResult = struct {
    conn: u64,
    remote: IpAddress,
};

/// How the application or kernel is told that a socket became ready.
pub const Notifier = struct {
    ptr: *anyopaque,
    notify: *const fn (*anyopaque, kind: Kind, handle: u64) void,

    pub const Kind = enum { connection, listener };
};

/// The fabric's view of the shared network runtime.
pub const Fabric = struct {
    world: *World,
    nodes: usize,
    down_nodes: []const bool,
    registry: *faults_module.Registry,
    faults: *const types.NetworkFaultOptions,
    address_model: types.AddressModel,
};

pub const Options = struct {
    timing: Timing,
    send_buffer_bytes: usize,
    receive_buffer_bytes: usize,
    mss: usize,
};

pub const ephemeral_port_min: u16 = 32768;
pub const ephemeral_port_max: u16 = 60999;

pub const Engine = struct {
    pub const SocketErrorKind = SocketError;

    allocator: std.mem.Allocator,
    fabric: Fabric,
    options: Options,
    notifier: ?Notifier = null,
    events: std.PriorityQueue(Event, void, Event.order) = .empty,
    /// Segments waiting at a `hold` fault, oldest first.
    held: std.ArrayList(*Segment) = .empty,
    connections: std.AutoArrayHashMapUnmanaged(u64, *Connection) = .empty,
    listeners: std.AutoArrayHashMapUnmanaged(u64, *Listener) = .empty,
    next_ephemeral: []u16,
    shared_ephemeral: u16 = ephemeral_port_min,
    next_id: u64 = 1,
    next_packet: u64 = 0,
    next_event_seq: u64 = 0,
    pumping: bool = false,
    /// Extra host names resolved by the simulated DNS.
    names: std.ArrayList(Name) = .empty,

    const Name = struct {
        name: []u8,
        host: NodeId,
    };

    pub fn init(allocator: std.mem.Allocator, fabric: Fabric, options: Options) !Engine {
        const next_ephemeral = try allocator.alloc(u16, fabric.nodes);
        @memset(next_ephemeral, ephemeral_port_min);
        return .{
            .allocator = allocator,
            .fabric = fabric,
            .options = options,
            .next_ephemeral = next_ephemeral,
        };
    }

    pub fn deinit(self: *Engine) void {
        while (self.events.pop()) |event| self.freeEvent(event);
        self.events.deinit(self.allocator);
        for (self.held.items) |segment| self.freeSegment(segment);
        self.held.deinit(self.allocator);
        for (self.connections.values()) |conn| {
            conn.deinit(self.allocator);
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        for (self.listeners.values()) |listener| {
            listener.accept_queue.deinit(self.allocator);
            self.allocator.destroy(listener);
        }
        self.listeners.deinit(self.allocator);
        for (self.names.items) |entry| self.allocator.free(entry.name);
        self.names.deinit(self.allocator);
        self.allocator.free(self.next_ephemeral);
        self.* = undefined;
    }

    fn world(self: *Engine) *World {
        return self.fabric.world;
    }

    fn now(self: *Engine) Timestamp {
        return self.fabric.world.now();
    }

    fn freeEvent(self: *Engine, event: Event) void {
        switch (event.kind) {
            .segment => |segment| self.freeSegment(segment),
            .icmp, .timer => {},
        }
    }

    fn freeSegment(self: *Engine, segment: *Segment) void {
        self.allocator.free(segment.payload);
        self.allocator.destroy(segment);
    }

    fn allocId(self: *Engine) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn ceilTick(self: *Engine, duration_ns: Duration) Duration {
        return self.fabric.world.clock().ceilDuration(duration_ns);
    }

    fn sampleJitter(self: *Engine, comptime site: []const u8, maximum_ns: Duration) Duration {
        const tick = self.world().clock().tick_ns;
        const maximum_ticks = maximum_ns / tick;
        const ticks = if (maximum_ticks == std.math.maxInt(u64))
            self.world().chooseU64(site) catch 0
        else
            self.world().chooseIntLessThan(site, u64, maximum_ticks + 1) catch 0;
        return ticks * tick;
    }

    // ------------------------------------------------------------------
    // Addresses and names.

    /// Host-owned IPv4 address: `10.0.0.0/8` offset by `node + 1`.
    pub fn hostIp4(node: NodeId, port: u16) IpAddress {
        const value: u32 = @as(u32, node) + 1;
        return .{ .ip4 = .{
            .bytes = .{ 10, @truncate(value >> 16), @truncate(value >> 8), @truncate(value) },
            .port = port,
        } };
    }

    /// Host-owned IPv6 address: `fd00::/8` offset by `node + 1`.
    pub fn hostIp6(node: NodeId, port: u16) IpAddress {
        const value: u32 = @as(u32, node) + 1;
        var bytes: [16]u8 = @splat(0);
        bytes[0] = 0xfd;
        std.mem.writeInt(u32, bytes[12..16], value, .big);
        return .{ .ip6 = .{ .bytes = bytes, .port = port } };
    }

    pub fn registerName(self: *Engine, name: []const u8, host: NodeId) !void {
        if (@as(usize, host) >= self.fabric.nodes) return error.InvalidNode;
        for (self.names.items) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                entry.host = host;
                return;
            }
        }
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.names.append(self.allocator, .{ .name = owned, .host = host });
    }

    /// Resolve a simulated host name: registered names, then `nodeN`.
    pub fn resolveName(self: *const Engine, name_with_dot: []const u8) ?NodeId {
        const name = if (name_with_dot.len > 0 and name_with_dot[name_with_dot.len - 1] == '.')
            name_with_dot[0 .. name_with_dot.len - 1]
        else
            name_with_dot;
        for (self.names.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.host;
        }
        if (name.len > 4 and std.ascii.eqlIgnoreCase(name[0..4], "node")) {
            const index = std.fmt.parseInt(NodeId, name[4..], 10) catch return null;
            if (@as(usize, index) < self.fabric.nodes) return index;
        }
        return null;
    }

    fn isLoopback(address: IpAddress) bool {
        return switch (address) {
            .ip4 => |ip4| ip4.bytes[0] == 127,
            .ip6 => |ip6| ip6.isLoopBack(),
        };
    }

    fn isUnspecified(address: IpAddress) bool {
        return switch (address) {
            .ip4 => |ip4| std.mem.allEqual(u8, &ip4.bytes, 0),
            .ip6 => |ip6| std.mem.allEqual(u8, &ip6.bytes, 0),
        };
    }

    fn sameIp(a: IpAddress, b: IpAddress) bool {
        return switch (a) {
            .ip4 => |x| switch (b) {
                .ip4 => |y| std.mem.eql(u8, &x.bytes, &y.bytes),
                .ip6 => false,
            },
            .ip6 => |x| switch (b) {
                .ip6 => |y| std.mem.eql(u8, &x.bytes, &y.bytes),
                .ip4 => false,
            },
        };
    }

    fn sameFamily(a: IpAddress, b: IpAddress) bool {
        return std.meta.activeTag(a) == std.meta.activeTag(b);
    }

    fn sameEndpoint(a: IpAddress, b: IpAddress) bool {
        return sameIp(a, b) and a.getPort() == b.getPort();
    }

    fn inSimulatedSubnet(address: IpAddress) bool {
        return switch (address) {
            .ip4 => |ip4| ip4.bytes[0] == 10,
            .ip6 => |ip6| ip6.bytes[0] == 0xfd,
        };
    }

    /// The host owning `address`, if any host does.
    fn hostOwning(self: *const Engine, address: IpAddress) ?NodeId {
        switch (address) {
            .ip4 => |ip4| {
                if (ip4.bytes[0] != 10) return null;
                const value = (@as(u32, ip4.bytes[1]) << 16) | (@as(u32, ip4.bytes[2]) << 8) | ip4.bytes[3];
                if (value == 0 or value > self.fabric.nodes) return null;
                return @intCast(value - 1);
            },
            .ip6 => |ip6| {
                if (ip6.bytes[0] != 0xfd) return null;
                if (!std.mem.allEqual(u8, ip6.bytes[1..12], 0)) return null;
                const value = std.mem.readInt(u32, ip6.bytes[12..16], .big);
                if (value == 0 or value > self.fabric.nodes) return null;
                return @intCast(value - 1);
            },
        }
    }

    /// Whether `host` may bind `address` (unspecified, loopback, or its own).
    fn hostMayBind(self: *const Engine, host: NodeId, address: IpAddress) bool {
        if (self.fabric.address_model == .shared_v0) return true;
        if (isUnspecified(address) or isLoopback(address)) return true;
        return self.hostOwning(address) == host;
    }

    fn listenerMatches(self: *const Engine, listener: *const Listener, host: NodeId, dst: IpAddress) bool {
        if (listener.closed) return false;
        if (self.fabric.address_model == .per_host_v1 and listener.host != host) return false;
        if (!sameFamily(listener.address, dst)) return false;
        if (listener.address.getPort() != dst.getPort()) return false;
        if (isUnspecified(listener.address)) return true;
        return sameIp(listener.address, dst);
    }

    fn listenerConflicts(self: *const Engine, existing: *const Listener, host: NodeId, candidate: IpAddress) bool {
        if (existing.closed) return false;
        if (self.fabric.address_model == .per_host_v1 and existing.host != host) return false;
        if (!sameFamily(existing.address, candidate)) return false;
        if (existing.address.getPort() != candidate.getPort()) return false;
        return isUnspecified(existing.address) or isUnspecified(candidate) or sameIp(existing.address, candidate);
    }

    fn portInUse(self: *const Engine, host: NodeId, family_address: IpAddress, port: u16) bool {
        var candidate = family_address;
        candidate.setPort(port);
        for (self.listeners.values()) |listener| {
            if (self.listenerConflicts(listener, host, candidate)) return true;
        }
        for (self.connections.values()) |conn| {
            if (self.fabric.address_model == .per_host_v1 and conn.host != host) continue;
            if (conn.local.getPort() == port and sameFamily(conn.local, family_address)) return true;
        }
        return false;
    }

    fn allocateEphemeral(self: *Engine, host: NodeId, family_address: IpAddress) ?u16 {
        const cursor = if (self.fabric.address_model == .per_host_v1)
            &self.next_ephemeral[host]
        else
            &self.shared_ephemeral;
        const range: u32 = @as(u32, ephemeral_port_max - ephemeral_port_min) + 1;
        var attempts: u32 = 0;
        while (attempts < range) : (attempts += 1) {
            const port = cursor.*;
            cursor.* = if (port == ephemeral_port_max) ephemeral_port_min else port + 1;
            if (!self.portInUse(host, family_address, port)) return port;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Listeners.

    pub const ListenError = error{ AddressInUse, AddressUnavailable, NetworkDown, OutOfMemory } || TraceErrors;
    const TraceErrors = error{InvalidTracePayload};

    pub fn listen(self: *Engine, host: NodeId, address: IpAddress, backlog: u31, handle: u64) ListenError!struct { id: u64, address: IpAddress } {
        defer self.pumpQuiet();
        if (!self.hostMayBind(host, address)) return error.AddressUnavailable;
        var bound = address;
        if (bound.getPort() == 0) {
            bound.setPort(self.allocateEphemeral(host, bound) orelse return error.AddressInUse);
        } else {
            for (self.listeners.values()) |listener| {
                if (self.listenerConflicts(listener, host, bound)) return error.AddressInUse;
            }
        }
        const listener = try self.allocator.create(Listener);
        errdefer self.allocator.destroy(listener);
        listener.* = .{
            .id = self.allocId(),
            .host = host,
            .address = bound,
            .backlog = @max(backlog, 1),
            .handle = handle,
        };
        try self.listeners.put(self.allocator, listener.id, listener);
        errdefer _ = self.listeners.orderedRemove(listener.id);
        try self.world().record("tcp.listen sock={} host={} addr={f} backlog={}", .{ listener.id, host, bound, listener.backlog });
        return .{ .id = listener.id, .address = bound };
    }

    pub fn closeListener(self: *Engine, id: u64) void {
        defer self.pumpQuiet();
        const listener = self.listeners.get(id) orelse return;
        self.world().record("tcp.listen_close sock={} pending={}", .{ id, listener.accept_queue.items.len }) catch {};
        // Connections the application never accepted are reset, as when a
        // Linux listener with a nonempty accept queue closes.
        for (listener.accept_queue.items) |conn_id| {
            if (self.connections.get(conn_id)) |conn| {
                conn.listener = null;
                self.resetConnection(conn, "listener_closed");
            }
        }
        for (self.connections.values()) |conn| {
            if (conn.listener == id and conn.state == .syn_received) {
                conn.listener = null;
                self.resetConnection(conn, "listener_closed");
            }
        }
        listener.accept_queue.deinit(self.allocator);
        _ = self.listeners.orderedRemove(id);
        self.allocator.destroy(listener);
        self.reapClosed();
    }

    pub const AcceptOutcome = union(enum) {
        accepted: AcceptResult,
        would_block,
        not_listening,
    };

    /// Take the oldest established connection. The caller must `attach`
    /// its handle before the next engine call.
    pub fn accept(self: *Engine, id: u64) AcceptOutcome {
        self.pumpQuiet();
        const listener = self.listeners.get(id) orelse return .not_listening;
        if (listener.closed) return .not_listening;
        if (listener.accept_queue.items.len == 0) return .would_block;
        const conn_id = listener.accept_queue.orderedRemove(0);
        const conn = self.connections.get(conn_id).?;
        conn.listener = null;
        return .{ .accepted = .{ .conn = conn_id, .remote = conn.remote } };
    }

    pub fn attach(self: *Engine, conn_id: u64, handle: u64, listener_id: u64) void {
        const conn = self.connections.get(conn_id) orelse return;
        conn.handle = handle;
        self.world().record("tcp.accept sock={} conn={} handle={} remote={f}", .{ listener_id, conn_id, handle, conn.remote }) catch {};
    }

    // ------------------------------------------------------------------
    // Connections.

    pub const ConnectError = error{ NetworkUnreachable, AddressUnavailable, NetworkDown, OutOfMemory } || TraceErrors;

    pub fn connect(self: *Engine, host: NodeId, destination: IpAddress, handle: u64) ConnectError!u64 {
        defer self.pumpQuiet();
        if (self.fabric.down_nodes[host]) return error.NetworkDown;

        var peer_host: ?NodeId = null;
        var arp_failure = false;
        var source = destination;
        switch (self.fabric.address_model) {
            .per_host_v1 => {
                if (isLoopback(destination) or isUnspecified(destination)) {
                    peer_host = host;
                    source = switch (destination) {
                        .ip4 => .{ .ip4 = .loopback(0) },
                        .ip6 => .{ .ip6 = .loopback(0) },
                    };
                } else if (self.hostOwning(destination)) |owner| {
                    peer_host = owner;
                    source = switch (destination) {
                        .ip4 => hostIp4(host, 0),
                        .ip6 => hostIp6(host, 0),
                    };
                    if (owner == host) source = destination;
                } else if (inSimulatedSubnet(destination)) {
                    arp_failure = true;
                    source = switch (destination) {
                        .ip4 => hostIp4(host, 0),
                        .ip6 => hostIp6(host, 0),
                    };
                } else {
                    return error.NetworkUnreachable;
                }
            },
            .shared_v0 => {
                source = destination;
                for (self.listeners.values()) |listener| {
                    if (self.listenerMatches(listener, listener.host, destination)) {
                        peer_host = listener.host;
                        break;
                    }
                }
                if (peer_host == null) peer_host = host;
            },
        }

        const port = self.allocateEphemeral(host, source) orelse return error.AddressUnavailable;
        source.setPort(port);

        const conn = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(conn);
        conn.* = .{
            .id = self.allocId(),
            .host = host,
            .peer_host = peer_host orelse host,
            .local = source,
            .remote = destination,
            .state = .syn_sent,
            .handle = handle,
            .send_capacity = self.options.send_buffer_bytes,
            .recv_capacity = self.options.receive_buffer_bytes,
            .rto_ns = self.ceilTick(self.options.timing.syn_rto_ns),
        };
        try self.connections.put(self.allocator, conn.id, conn);
        errdefer _ = self.connections.orderedRemove(conn.id);
        try self.world().record("tcp.connect conn={} host={} src={f} dst={f}", .{ conn.id, host, conn.local, destination });

        if (arp_failure) {
            self.armTimer(conn, .arp, self.options.timing.arp_failure_ns);
        } else {
            self.sendControl(conn, .{ .syn = true }, 0);
            conn.snd_nxt = 1;
            conn.rtt_sample = .{ .seq = 1, .sent_at = self.now() };
            self.armTimer(conn, .rto, conn.rto_ns);
        }
        return conn.id;
    }

    pub fn connectStatus(self: *Engine, id: u64) ConnectStatus {
        self.pumpQuiet();
        const conn = self.connections.get(id) orelse return .{ .failed = .reset };
        if (conn.err) |err| return .{ .failed = err };
        return switch (conn.state) {
            .syn_sent, .syn_received => .pending,
            .closed => .{ .failed = conn.terminal orelse .reset },
            else => .established,
        };
    }

    /// Drop a connection without a FIN: the application gave up on
    /// `connect` or a pending socket. Established peers receive an RST.
    pub fn abort(self: *Engine, id: u64) void {
        defer self.pumpQuiet();
        const conn = self.connections.get(id) orelse return;
        conn.handle = null;
        conn.orphan = true;
        switch (conn.state) {
            .syn_sent, .closed, .time_wait => self.setState(conn, .closed),
            else => self.resetConnection(conn, "abort"),
        }
        self.reapClosed();
    }

    pub fn localAddress(self: *Engine, id: u64) ?IpAddress {
        const conn = self.connections.get(id) orelse return null;
        return conn.local;
    }

    pub fn remoteAddress(self: *Engine, id: u64) ?IpAddress {
        const conn = self.connections.get(id) orelse return null;
        return conn.remote;
    }

    pub fn read(self: *Engine, id: u64, data: []const []u8) ReadResult {
        self.pumpQuiet();
        defer self.pumpQuiet();
        const conn = self.connections.get(id) orelse return .not_connected;
        if (conn.read_shutdown) return .end_of_stream;
        if (conn.state == .syn_sent or conn.state == .syn_received) {
            if (conn.err) |err| {
                conn.err = null;
                return .{ .failed = err };
            }
            return .would_block;
        }
        if (conn.recv_buf.items.len > 0) {
            var total: usize = 0;
            for (data) |buffer| {
                const count = @min(buffer.len, conn.recv_buf.items.len - total);
                @memcpy(buffer[0..count], conn.recv_buf.items[total..][0..count]);
                total += count;
                if (total == conn.recv_buf.items.len) break;
            }
            conn.recv_buf.replaceRangeAssumeCapacity(0, total, &.{});
            self.maybeWindowUpdate(conn);
            return .{ .bytes = total };
        }
        if (conn.err) |err| {
            conn.err = null;
            return .{ .failed = err };
        }
        if (conn.fin_received or conn.state == .closed) return .end_of_stream;
        return .would_block;
    }

    pub fn write(self: *Engine, id: u64, header: []const u8, data: []const []const u8, splat: usize) error{OutOfMemory}!WriteResult {
        self.pumpQuiet();
        defer self.pumpQuiet();
        const conn = self.connections.get(id) orelse return .not_connected;
        if (conn.err) |err| {
            conn.err = null;
            return .{ .failed = err };
        }
        if (conn.terminal) |err| return .{ .failed = err };
        switch (conn.state) {
            .established, .close_wait => {},
            .syn_sent, .syn_received => return .would_block,
            else => return .not_connected,
        }
        if (conn.fin_queued) return .not_connected;

        var total_len: usize = header.len;
        if (data.len > 0) {
            for (data[0 .. data.len - 1]) |bytes| total_len += bytes.len;
            total_len += data[data.len - 1].len * splat;
        }
        if (total_len == 0) return .{ .accepted = 0 };
        const space = conn.send_capacity -| conn.send_buf.items.len;
        if (space == 0) return .would_block;

        var remaining = @min(space, total_len);
        const accepted = remaining;
        try conn.send_buf.ensureUnusedCapacity(self.allocator, remaining);
        remaining -= appendLimited(&conn.send_buf, header, remaining);
        if (data.len > 0) {
            for (data[0 .. data.len - 1]) |bytes| remaining -= appendLimited(&conn.send_buf, bytes, remaining);
            const pattern = data[data.len - 1];
            var copies: usize = 0;
            while (copies < splat and remaining > 0) : (copies += 1) {
                remaining -= appendLimited(&conn.send_buf, pattern, remaining);
            }
        }
        std.debug.assert(remaining == 0);
        self.output(conn);
        return .{ .accepted = accepted };
    }

    fn appendLimited(list: *std.ArrayList(u8), bytes: []const u8, limit: usize) usize {
        const count = @min(bytes.len, limit);
        list.appendSliceAssumeCapacity(bytes[0..count]);
        return count;
    }

    pub const ShutdownHow = enum { recv, send, both };

    pub fn shutdown(self: *Engine, id: u64, how: ShutdownHow) bool {
        defer self.pumpQuiet();
        const conn = self.connections.get(id) orelse return false;
        if (how == .recv or how == .both) {
            conn.read_shutdown = true;
            conn.recv_buf.clearRetainingCapacity();
        }
        if (how == .send or how == .both) self.queueFin(conn);
        self.notifyConnection(conn);
        return true;
    }

    /// The application closes its socket. Unread data resets the peer, as
    /// on Linux; otherwise the kernel sends any buffered data and a FIN and
    /// finishes the connection as an orphan.
    pub fn close(self: *Engine, id: u64) void {
        defer self.pumpQuiet();
        const conn = self.connections.get(id) orelse return;
        conn.handle = null;
        conn.orphan = true;
        self.closeByKernel(conn, "close");
        self.reapClosed();
    }

    fn closeByKernel(self: *Engine, conn: *Connection, comptime reason: []const u8) void {
        switch (conn.state) {
            .syn_sent => self.setState(conn, .closed),
            .closed, .time_wait, .fin_wait_2, .closing, .last_ack, .fin_wait_1 => {},
            .syn_received, .established, .close_wait => {
                if (conn.recv_buf.items.len > 0 and !conn.read_shutdown) {
                    self.resetConnection(conn, reason ++ "_unread");
                } else {
                    self.queueFin(conn);
                }
            },
        }
        if (conn.state == .fin_wait_2) self.armTimer(conn, .fin_wait2, self.options.timing.fin_wait2_ns);
    }

    /// A process exited: its kernel closes every socket it held.
    pub fn processExit(self: *Engine, host: NodeId) void {
        defer self.pumpQuiet();
        var listener_index: usize = 0;
        while (listener_index < self.listeners.count()) {
            const listener = self.listeners.values()[listener_index];
            if (listener.host != host) {
                listener_index += 1;
                continue;
            }
            self.closeListener(listener.id);
        }
        for (self.connections.values()) |conn| {
            if (conn.host != host or conn.handle == null) continue;
            conn.handle = null;
            conn.orphan = true;
            self.closeByKernel(conn, "exit");
        }
        self.reapClosed();
    }

    /// The machine crashed: its sockets vanish without sending anything.
    pub fn machineCrash(self: *Engine, host: NodeId) void {
        defer self.pumpQuiet();
        var index: usize = 0;
        while (index < self.listeners.count()) {
            const listener = self.listeners.values()[index];
            if (listener.host != host) {
                index += 1;
                continue;
            }
            listener.accept_queue.deinit(self.allocator);
            _ = self.listeners.orderedRemove(listener.id);
            self.allocator.destroy(listener);
        }
        for (self.connections.values()) |conn| {
            if (conn.host != host) continue;
            conn.handle = null;
            conn.orphan = true;
            conn.listener = null;
            conn.state = .closed;
        }
        self.world().record("tcp.machine_crash host={}", .{host}) catch {};
        self.reapClosed();
    }

    /// Detach the application from a socket whose process was killed, so
    /// stale handles cannot reach it.
    pub fn detachHandle(self: *Engine, id: u64) void {
        if (self.connections.get(id)) |conn| conn.handle = null;
    }

    // ------------------------------------------------------------------
    // Segments.

    fn segmentFor(self: *Engine, conn: *Connection, flags: Flags, seq: u64, payload: []const u8) ?*Segment {
        const segment = self.allocator.create(Segment) catch return null;
        const owned = self.allocator.dupe(u8, payload) catch {
            self.allocator.destroy(segment);
            return null;
        };
        segment.* = .{
            .id = self.next_packet,
            .from = conn.host,
            .to = conn.peer_host,
            .src = conn.local,
            .dst = conn.remote,
            .flags = flags,
            .seq = seq,
            .ack = conn.rcv_nxt,
            .wnd = conn.window(),
            .payload = owned,
        };
        self.next_packet += 1;
        if (flags.ack) {
            conn.ack_pending = 0;
            conn.last_advertised = segment.wnd;
            self.cancelTimer(conn, .delayed_ack);
        }
        return segment;
    }

    fn sendControl(self: *Engine, conn: *Connection, flags: Flags, seq: u64) void {
        const segment = self.segmentFor(conn, flags, seq, &.{}) orelse return;
        self.transmit(segment);
    }

    fn sendAck(self: *Engine, conn: *Connection) void {
        self.sendControl(conn, .{ .ack = true }, conn.snd_nxt);
    }

    fn sendData(self: *Engine, conn: *Connection, seq: u64, len: usize) void {
        const offset: usize = @intCast(seq - conn.send_seq);
        const segment = self.segmentFor(conn, .{ .ack = true }, seq, conn.send_buf.items[offset..][0..len]) orelse return;
        self.transmit(segment);
    }

    fn sendRstReply(self: *Engine, segment: *const Segment) void {
        if (segment.flags.rst) return;
        const reply = self.allocator.create(Segment) catch return;
        reply.* = .{
            .id = self.next_packet,
            .from = segment.to,
            .to = segment.from,
            .src = segment.dst,
            .dst = segment.src,
            .flags = if (segment.flags.ack) .{ .rst = true } else .{ .rst = true, .ack = true },
            .seq = if (segment.flags.ack) segment.ack else 0,
            .ack = segment.seq + segment.seqLen(),
            .wnd = 0,
            .payload = &.{},
        };
        self.next_packet += 1;
        self.transmit(reply);
    }

    /// Put a segment on the wire: loss and source state are decided now,
    /// fault fate when it arrives.
    fn transmit(self: *Engine, segment: *Segment) void {
        const world_ptr = self.world();
        var flag_buffer: [12]u8 = undefined;
        const flags = segment.flags.label(&flag_buffer);
        if (self.fabric.down_nodes[segment.from]) {
            world_ptr.record("net.drop pkt={} from={} to={} reason=source_down", .{ segment.id, segment.from, segment.to }) catch {};
            self.freeSegment(segment);
            return;
        }
        const path = self.fabric.registry.pathIndex(segment.from, segment.to);
        const loopback = segment.from == segment.to;
        const options = self.fabric.faults;
        if (!loopback and options.drop_rate.numerator > 0) {
            const roll = world_ptr.chooseIntLessThan("network.tcp_drop", u32, options.drop_rate.denominator) catch 0;
            if (options.drop_rate.fires(roll)) {
                world_ptr.record(
                    "net.send pkt={} from={} to={} src={f} dst={f} flags={s} seq={} ack={} len={} wnd={}",
                    .{ segment.id, segment.from, segment.to, segment.src, segment.dst, flags, segment.seq, segment.ack, segment.payload.len, segment.wnd },
                ) catch {};
                world_ptr.record("net.drop pkt={} from={} to={} reason=loss roll={}", .{ segment.id, segment.from, segment.to, roll }) catch {};
                self.freeSegment(segment);
                return;
            }
        }

        var delay: Duration = 0;
        if (!loopback) {
            delay = options.min_latency_ns;
            if (options.latency_jitter_ns > 0) {
                delay +|= self.sampleJitter("network.tcp_latency", options.latency_jitter_ns);
            }
            for (self.fabric.registry.faults.items) |*fault| {
                if (!fault.covers(path)) continue;
                if (fault.mode == .slow) {
                    delay +|= fault.delay_ns;
                    if (fault.jitter_ns > 0) {
                        delay +|= self.sampleJitter("network.tcp_degrade_latency", fault.jitter_ns);
                    }
                    if (fault.drop_rate.numerator > 0) {
                        const roll = world_ptr.chooseIntLessThan("network.tcp_degrade_drop", u32, fault.drop_rate.denominator) catch 0;
                        if (fault.drop_rate.fires(roll)) {
                            world_ptr.record(
                                "net.send pkt={} from={} to={} src={f} dst={f} flags={s} seq={} ack={} len={} wnd={}",
                                .{ segment.id, segment.from, segment.to, segment.src, segment.dst, flags, segment.seq, segment.ack, segment.payload.len, segment.wnd },
                            ) catch {};
                            world_ptr.record("net.drop pkt={} from={} to={} reason=fault fault={} mode=slow roll={}", .{ segment.id, segment.from, segment.to, fault.id, roll }) catch {};
                            self.freeSegment(segment);
                            return;
                        }
                    }
                }
            }
        }
        const at = self.now() +| self.ceilTick(delay);
        world_ptr.record(
            "net.send pkt={} from={} to={} src={f} dst={f} flags={s} seq={} ack={} len={} wnd={} deliver_at={}",
            .{ segment.id, segment.from, segment.to, segment.src, segment.dst, flags, segment.seq, segment.ack, segment.payload.len, segment.wnd, at },
        ) catch {};
        self.schedule(at, .{ .segment = segment }) catch self.freeSegment(segment);
    }

    fn schedule(self: *Engine, at: Timestamp, kind: Event.Kind) !void {
        try self.events.push(self.allocator, .{ .at = at, .seq = self.next_event_seq, .kind = kind });
        self.next_event_seq += 1;
    }

    fn arrive(self: *Engine, segment: *Segment) void {
        const world_ptr = self.world();
        if (segment.from != segment.to) {
            const path = self.fabric.registry.pathIndex(segment.from, segment.to);
            const verdict = self.fabric.registry.verdict(path);
            if (verdict.blocked) |blocked| switch (blocked.mode) {
                .drop => {
                    world_ptr.record("net.drop pkt={} from={} to={} reason=fault fault={} mode=drop", .{ segment.id, segment.from, segment.to, blocked.fault }) catch {};
                    self.freeSegment(segment);
                    return;
                },
                .reject => {
                    world_ptr.record("net.drop pkt={} from={} to={} reason=fault fault={} mode=reject", .{ segment.id, segment.from, segment.to, blocked.fault }) catch {};
                    // The refusing hop answers the sender. The signal
                    // crosses back one base latency later.
                    const back = self.now() +| self.ceilTick(self.fabric.faults.min_latency_ns);
                    self.schedule(back, .{ .icmp = .{
                        .packet = segment.id,
                        .to = segment.from,
                        .src = segment.src,
                        .dst = segment.dst,
                        .fault = blocked.fault,
                    } }) catch {};
                    self.freeSegment(segment);
                    return;
                },
                .hold, .slow => unreachable,
            };
            if (verdict.held_by) |fault| {
                world_ptr.record("net.hold pkt={} fault={}", .{ segment.id, fault }) catch {};
                self.held.append(self.allocator, segment) catch {
                    world_ptr.record("net.drop pkt={} from={} to={} reason=hold_overflow", .{ segment.id, segment.from, segment.to }) catch {};
                    self.freeSegment(segment);
                };
                return;
            }
        }
        if (self.fabric.down_nodes[segment.to]) {
            world_ptr.record("net.drop pkt={} from={} to={} reason=destination_down", .{ segment.id, segment.from, segment.to }) catch {};
            self.freeSegment(segment);
            return;
        }
        defer self.freeSegment(segment);

        if (self.findConnection(segment.to, segment.dst, segment.src)) |conn| {
            world_ptr.record("net.deliver pkt={} from={} to={} conn={}", .{ segment.id, segment.from, segment.to, conn.id }) catch {};
            self.input(conn, segment);
            return;
        }
        if (segment.flags.syn and !segment.flags.ack and !segment.flags.rst) {
            for (self.listeners.values()) |listener| {
                if (!self.listenerMatches(listener, segment.to, segment.dst)) continue;
                world_ptr.record("net.deliver pkt={} from={} to={} sock={}", .{ segment.id, segment.from, segment.to, listener.id }) catch {};
                self.acceptSyn(listener, segment);
                return;
            }
        }
        world_ptr.record("net.deliver pkt={} from={} to={} socket=none", .{ segment.id, segment.from, segment.to }) catch {};
        self.sendRstReply(segment);
    }

    fn findConnection(self: *Engine, host: NodeId, local: IpAddress, remote: IpAddress) ?*Connection {
        for (self.connections.values()) |conn| {
            if (conn.host != host) continue;
            if (conn.state == .closed) continue;
            if (!sameEndpoint(conn.local, local)) continue;
            if (!sameEndpoint(conn.remote, remote)) continue;
            return conn;
        }
        return null;
    }

    fn acceptSyn(self: *Engine, listener: *Listener, segment: *const Segment) void {
        var embryonic: usize = 0;
        for (self.connections.values()) |conn| {
            if (conn.listener == listener.id and conn.state == .syn_received) embryonic += 1;
        }
        if (listener.accept_queue.items.len >= listener.backlog) {
            // Linux drops the SYN when the accept queue is full; the client
            // retransmits and may succeed once the application accepts.
            self.world().record("tcp.syn_drop sock={} reason=backlog_full accept_queue={}", .{ listener.id, listener.accept_queue.items.len }) catch {};
            return;
        }
        const conn = self.allocator.create(Connection) catch return;
        conn.* = .{
            .id = self.allocId(),
            .host = segment.to,
            .peer_host = segment.from,
            .local = segment.dst,
            .remote = segment.src,
            .state = .syn_received,
            .listener = listener.id,
            .send_capacity = self.options.send_buffer_bytes,
            .recv_capacity = self.options.receive_buffer_bytes,
            .rto_ns = self.ceilTick(self.options.timing.syn_rto_ns),
            .rcv_nxt = segment.seq + 1,
            .snd_wnd = segment.wnd,
        };
        self.connections.put(self.allocator, conn.id, conn) catch {
            self.allocator.destroy(conn);
            return;
        };
        self.world().record("tcp.state conn={} host={} state=SYN_RECV sock={} local={f} remote={f}", .{ conn.id, conn.host, listener.id, conn.local, conn.remote }) catch {};
        self.sendControl(conn, .{ .syn = true, .ack = true }, 0);
        conn.snd_nxt = 1;
        conn.rtt_sample = .{ .seq = 1, .sent_at = self.now() };
        self.armTimer(conn, .rto, conn.rto_ns);
    }

    fn input(self: *Engine, conn: *Connection, segment: *const Segment) void {
        if (segment.flags.rst) {
            switch (conn.state) {
                .syn_sent => {
                    if (segment.flags.ack and segment.ack == 1) self.fail(conn, .refused);
                },
                .time_wait => self.setState(conn, .closed),
                .syn_received => {
                    // A reset half-open connection is silently forgotten.
                    conn.listener = null;
                    self.setState(conn, .closed);
                },
                else => self.fail(conn, .reset),
            }
            self.reapClosed();
            return;
        }

        if (conn.state == .syn_sent) {
            if (!segment.flags.syn or !segment.flags.ack or segment.ack != 1) return;
            conn.rcv_nxt = segment.seq + 1;
            conn.snd_una = 1;
            conn.snd_wnd = segment.wnd;
            conn.retries = 0;
            self.sampleRtt(conn, segment.ack);
            self.cancelTimer(conn, .rto);
            self.setState(conn, .established);
            self.sendAck(conn);
            self.notifyConnection(conn);
            self.output(conn);
            return;
        }

        if (segment.flags.syn) {
            // A retransmitted SYN or SYN-ACK: our reply was lost. Answer
            // again so the peer can finish its handshake.
            if (conn.state == .syn_received) {
                self.sendControl(conn, .{ .syn = true, .ack = true }, 0);
            } else {
                self.sendAck(conn);
            }
            return;
        }
        if (!segment.flags.ack) return;

        if (conn.state == .syn_received) {
            if (segment.ack != 1) return;
            conn.snd_una = 1;
            conn.retries = 0;
            self.sampleRtt(conn, segment.ack);
            self.cancelTimer(conn, .rto);
            self.setState(conn, .established);
            if (conn.listener) |listener_id| {
                if (self.listeners.get(listener_id)) |listener| {
                    listener.accept_queue.append(self.allocator, conn.id) catch {};
                    self.notify(.listener, listener.handle);
                }
            }
        }

        self.processAck(conn, segment);
        if (conn.state == .closed) {
            self.reapClosed();
            return;
        }
        self.processData(conn, segment);
        self.output(conn);
        self.reapClosed();
    }

    fn processAck(self: *Engine, conn: *Connection, segment: *const Segment) void {
        const ack = segment.ack;
        if (ack > conn.snd_una and ack <= conn.snd_nxt) {
            const data_end = conn.sendEnd();
            const acked_data_end = @min(ack, data_end);
            if (acked_data_end > conn.send_seq) {
                const count: usize = @intCast(acked_data_end - conn.send_seq);
                conn.send_buf.replaceRangeAssumeCapacity(0, count, &.{});
                conn.send_seq = acked_data_end;
            }
            conn.snd_una = ack;
            conn.retries = 0;
            conn.dupacks = 0;
            conn.soft_err = null;
            self.sampleRtt(conn, ack);
            if (conn.inFlight()) self.armTimer(conn, .rto, conn.rto_ns) else self.cancelTimer(conn, .rto);
            if (conn.snd_una < conn.recover) {
                // Partial acknowledgment during recovery: the next hole is
                // already known lost; retransmit it without waiting.
                self.retransmitAt(conn, conn.snd_una);
            }
            self.notifyConnection(conn);
            if (conn.fin_sent and ack == conn.fin_seq + 1) self.finAcked(conn);
        } else if (ack == conn.snd_una and conn.inFlight() and segment.payload.len == 0 and
            !segment.flags.fin and segment.wnd == conn.snd_wnd)
        {
            conn.dupacks +|= 1;
            if (conn.dupacks == 3) {
                self.world().record("tcp.fast_retransmit conn={} seq={}", .{ conn.id, conn.snd_una }) catch {};
                conn.recover = conn.snd_nxt;
                self.retransmitAt(conn, conn.snd_una);
            }
        }
        if (ack >= conn.snd_una) {
            const was_zero = conn.snd_wnd == 0;
            conn.snd_wnd = segment.wnd;
            conn.persist_probes = 0;
            if (conn.snd_wnd > 0) {
                self.cancelTimer(conn, .persist);
                if (was_zero) conn.persist_backoff_ns = 0;
            }
        }
    }

    fn finAcked(self: *Engine, conn: *Connection) void {
        switch (conn.state) {
            .fin_wait_1 => {
                self.setState(conn, .fin_wait_2);
                if (conn.orphan) self.armTimer(conn, .fin_wait2, self.options.timing.fin_wait2_ns);
            },
            .closing => self.enterTimeWait(conn),
            .last_ack => self.setState(conn, .closed),
            else => {},
        }
    }

    fn enterTimeWait(self: *Engine, conn: *Connection) void {
        self.cancelTimer(conn, .rto);
        self.cancelTimer(conn, .fin_wait2);
        self.setState(conn, .time_wait);
        self.armTimer(conn, .time_wait, self.options.timing.time_wait_ns);
    }

    fn processData(self: *Engine, conn: *Connection, segment: *const Segment) void {
        if (segment.payload.len == 0 and !segment.flags.fin) {
            // A segment below the receive window (a window probe or a stray
            // duplicate) is answered with the current ACK and window.
            if (segment.seq < conn.rcv_nxt) self.sendAck(conn);
            return;
        }
        switch (conn.state) {
            .established, .fin_wait_1, .fin_wait_2 => {},
            else => {
                // Data after our side saw the FIN, or on a dying socket.
                self.sendAck(conn);
                return;
            },
        }

        if (segment.seq > conn.rcv_nxt) {
            self.storeOutOfOrder(conn, segment);
            self.sendAck(conn);
            return;
        }

        const advanced = self.acceptInOrder(conn, segment.seq, segment.payload, segment.flags.fin);
        if (!advanced) {
            // A duplicate: the peer missed our ACK.
            self.sendAck(conn);
            return;
        }
        self.drainOutOfOrder(conn);
        if (conn.fin_received or conn.out_of_order.items.len > 0) {
            self.sendAck(conn);
        } else {
            conn.ack_pending +|= 1;
            if (conn.ack_pending >= 2) {
                self.sendAck(conn);
            } else {
                self.armTimer(conn, .delayed_ack, self.options.timing.delayed_ack_ns);
            }
        }
        self.notifyConnection(conn);
    }

    /// Accept bytes starting at `seq` (<= rcv_nxt). Returns whether
    /// `rcv_nxt` advanced.
    fn acceptInOrder(self: *Engine, conn: *Connection, seq: u64, payload: []const u8, fin: bool) bool {
        const skip = conn.rcv_nxt - seq;
        if (skip > payload.len) return false;
        const fresh = payload[@intCast(skip)..];
        const room: usize = @intCast(@min(conn.window(), fresh.len));
        const take = fresh[0..room];
        if (!conn.read_shutdown) {
            conn.recv_buf.appendSlice(self.allocator, take) catch return false;
        }
        conn.rcv_nxt += take.len;
        var advanced = take.len > 0;
        if (fin and take.len == fresh.len and !conn.fin_received) {
            conn.rcv_nxt += 1;
            conn.fin_received = true;
            advanced = true;
            switch (conn.state) {
                .established => self.setState(conn, .close_wait),
                .fin_wait_1 => self.setState(conn, .closing),
                .fin_wait_2 => self.enterTimeWait(conn),
                else => {},
            }
        }
        return advanced;
    }

    fn storeOutOfOrder(self: *Engine, conn: *Connection, segment: *const Segment) void {
        const offset = segment.seq - conn.rcv_nxt;
        const window = conn.window();
        if (offset >= window) return;
        const room: usize = @intCast(@min(window - offset, segment.payload.len));
        for (conn.out_of_order.items) |entry| {
            if (entry.seq == segment.seq and entry.bytes.len >= room) return;
        }
        const bytes = self.allocator.dupe(u8, segment.payload[0..room]) catch return;
        var index: usize = 0;
        while (index < conn.out_of_order.items.len and conn.out_of_order.items[index].seq <= segment.seq) index += 1;
        conn.out_of_order.insert(self.allocator, index, .{
            .seq = segment.seq,
            .bytes = bytes,
            .fin = segment.flags.fin and room == segment.payload.len,
        }) catch self.allocator.free(bytes);
    }

    fn drainOutOfOrder(self: *Engine, conn: *Connection) void {
        while (conn.out_of_order.items.len > 0) {
            const entry = conn.out_of_order.items[0];
            if (entry.seq > conn.rcv_nxt) break;
            _ = conn.out_of_order.orderedRemove(0);
            defer self.allocator.free(entry.bytes);
            _ = self.acceptInOrder(conn, entry.seq, entry.bytes, entry.fin);
        }
    }

    fn output(self: *Engine, conn: *Connection) void {
        switch (conn.state) {
            .established, .close_wait, .fin_wait_1, .last_ack, .closing => {},
            else => return,
        }
        const mss = self.options.mss;
        while (true) {
            const data_end = conn.sendEnd();
            if (conn.snd_nxt < data_end) {
                const window_end = conn.snd_una + conn.snd_wnd;
                if (conn.snd_nxt >= window_end) {
                    if (conn.snd_wnd == 0 and !conn.inFlight()) self.armPersist(conn);
                    break;
                }
                const len: usize = @intCast(@min(@as(u64, mss), @min(data_end - conn.snd_nxt, window_end - conn.snd_nxt)));
                const seq = conn.snd_nxt;
                self.sendData(conn, seq, len);
                conn.snd_nxt += len;
                if (conn.rtt_sample == null) conn.rtt_sample = .{ .seq = conn.snd_nxt, .sent_at = self.now() };
                continue;
            }
            if (conn.fin_queued and !conn.fin_sent) {
                conn.fin_seq = conn.snd_nxt;
                conn.fin_sent = true;
                self.sendControl(conn, .{ .fin = true, .ack = true }, conn.fin_seq);
                conn.snd_nxt += 1;
                switch (conn.state) {
                    .established => self.setState(conn, .fin_wait_1),
                    .close_wait => self.setState(conn, .last_ack),
                    else => {},
                }
                continue;
            }
            break;
        }
        if (conn.inFlight() and !conn.timer_armed[@backingInt(TimerKind.rto)]) {
            self.armTimer(conn, .rto, conn.rto_ns);
        }
    }

    fn queueFin(self: *Engine, conn: *Connection) void {
        if (conn.fin_queued) return;
        switch (conn.state) {
            .established, .close_wait => {
                conn.fin_queued = true;
                self.output(conn);
            },
            .syn_received => {
                // Never accepted: finish the handshake's fate with an RST.
                self.resetConnection(conn, "close_half_open");
            },
            else => {},
        }
    }

    fn retransmitAt(self: *Engine, conn: *Connection, seq: u64) void {
        conn.rtt_sample = null; // Karn: never sample a retransmitted segment.
        if (seq == 0 and conn.state == .syn_sent) {
            self.sendControl(conn, .{ .syn = true }, 0);
            return;
        }
        if (seq == 0 and conn.state == .syn_received) {
            self.sendControl(conn, .{ .syn = true, .ack = true }, 0);
            return;
        }
        const data_end = conn.sendEnd();
        if (seq >= conn.send_seq and seq < data_end) {
            const len: usize = @intCast(@min(@as(u64, self.options.mss), data_end - seq));
            self.sendData(conn, seq, len);
            return;
        }
        if (conn.fin_sent and seq == conn.fin_seq) {
            self.sendControl(conn, .{ .fin = true, .ack = true }, conn.fin_seq);
        }
    }

    fn sampleRtt(self: *Engine, conn: *Connection, ack: u64) void {
        const sample = conn.rtt_sample orelse return;
        // `seq` is the end of the timed segment; its own ACK is the sample.
        if (ack < sample.seq) return;
        conn.rtt_sample = null;
        const rtt = self.now() - sample.sent_at;
        if (conn.srtt_ns) |srtt| {
            const delta = if (srtt > rtt) srtt - rtt else rtt - srtt;
            conn.rttvar_ns = (3 * conn.rttvar_ns + delta) / 4;
            conn.srtt_ns = (7 * srtt + rtt) / 8;
        } else {
            conn.srtt_ns = rtt;
            conn.rttvar_ns = rtt / 2;
        }
        const tick = self.fabric.world.clock().tick_ns;
        const rto = conn.srtt_ns.? +| @max(tick, 4 * conn.rttvar_ns);
        conn.rto_ns = self.ceilTick(std.math.clamp(rto, self.options.timing.min_rto_ns, self.options.timing.max_rto_ns));
    }

    fn armPersist(self: *Engine, conn: *Connection) void {
        if (conn.timer_armed[@backingInt(TimerKind.persist)]) return;
        if (conn.persist_backoff_ns == 0) conn.persist_backoff_ns = conn.rto_ns;
        self.armTimer(conn, .persist, conn.persist_backoff_ns);
    }

    fn maybeWindowUpdate(self: *Engine, conn: *Connection) void {
        switch (conn.state) {
            .established, .fin_wait_1, .fin_wait_2 => {},
            else => return,
        }
        const current = conn.window();
        const mss: u64 = self.options.mss;
        const threshold = @min(2 * mss, conn.recv_capacity / 2);
        if (conn.last_advertised < mss and current >= mss or current >= conn.last_advertised + threshold) {
            self.sendAck(conn);
        }
    }

    // ------------------------------------------------------------------
    // State, errors, and timers.

    fn setState(self: *Engine, conn: *Connection, state: State) void {
        if (conn.state == state) return;
        conn.state = state;
        self.world().record("tcp.state conn={} host={} state={s}", .{ conn.id, conn.host, state.label() }) catch {};
        if (state == .closed) {
            for (&conn.timer_armed) |*armed| armed.* = false;
            for (&conn.timer_generation) |*generation| generation.* += 1;
        }
    }

    fn fail(self: *Engine, conn: *Connection, err: SocketError) void {
        self.world().record("tcp.error conn={} host={} error={s} state={s}", .{ conn.id, conn.host, @tagName(err), conn.state.label() }) catch {};
        // A socket still in an accept queue keeps its error too: `accept`
        // returns it, and the first read reports the error.
        if (conn.handle != null or conn.listener != null) {
            conn.err = err;
            conn.terminal = err;
        }
        self.setState(conn, .closed);
        self.notifyConnection(conn);
    }

    fn resetConnection(self: *Engine, conn: *Connection, reason: []const u8) void {
        self.world().record("tcp.reset conn={} host={} reason={s}", .{ conn.id, conn.host, reason }) catch {};
        if (conn.state != .syn_sent and conn.state != .closed) {
            self.sendControl(conn, .{ .rst = true, .ack = true }, conn.snd_nxt);
        }
        self.setState(conn, .closed);
        self.notifyConnection(conn);
    }

    fn armTimer(self: *Engine, conn: *Connection, kind: TimerKind, duration_ns: Duration) void {
        const index = @backingInt(kind);
        conn.timer_generation[index] += 1;
        conn.timer_armed[index] = true;
        const at = self.now() +| self.ceilTick(@max(duration_ns, 1));
        self.schedule(at, .{ .timer = .{ .conn = conn.id, .kind = kind, .generation = conn.timer_generation[index] } }) catch {
            conn.timer_armed[index] = false;
        };
    }

    fn cancelTimer(_: *Engine, conn: *Connection, kind: TimerKind) void {
        const index = @backingInt(kind);
        if (!conn.timer_armed[index]) return;
        conn.timer_armed[index] = false;
        conn.timer_generation[index] += 1;
    }

    fn timerLive(self: *const Engine, timer: Event.Timer) ?*Connection {
        const conn = self.connections.get(timer.conn) orelse return null;
        const index = @backingInt(timer.kind);
        if (!conn.timer_armed[index] or conn.timer_generation[index] != timer.generation) return null;
        return conn;
    }

    fn fire(self: *Engine, timer: Event.Timer) void {
        const conn = self.timerLive(timer) orelse return;
        conn.timer_armed[@backingInt(timer.kind)] = false;
        switch (timer.kind) {
            .rto => self.onRetransmitTimeout(conn),
            .delayed_ack => if (conn.ack_pending > 0) self.sendAck(conn),
            .persist => self.onPersist(conn),
            .fin_wait2 => {
                if (conn.state == .fin_wait_2 and conn.orphan) {
                    self.world().record("tcp.fin_wait2_timeout conn={}", .{conn.id}) catch {};
                    self.setState(conn, .closed);
                }
            },
            .time_wait => if (conn.state == .time_wait) self.setState(conn, .closed),
            .arp => self.fail(conn, .host_unreachable),
        }
        self.reapClosed();
    }

    fn onRetransmitTimeout(self: *Engine, conn: *Connection) void {
        if (!conn.inFlight()) return;
        const limit = switch (conn.state) {
            .syn_sent => self.options.timing.syn_retries,
            .syn_received => self.options.timing.synack_retries,
            else => self.options.timing.data_retries,
        };
        if (conn.retries >= limit) {
            if (conn.state == .syn_received) {
                self.world().record("tcp.timeout conn={} state=SYN_RECV", .{conn.id}) catch {};
                conn.listener = null;
                self.setState(conn, .closed);
                return;
            }
            self.fail(conn, conn.soft_err orelse .timed_out);
            return;
        }
        conn.retries += 1;
        conn.rto_ns = self.ceilTick(@min(conn.rto_ns *| 2, self.options.timing.max_rto_ns));
        conn.recover = conn.snd_nxt;
        conn.dupacks = 0;
        self.world().record("tcp.retransmit conn={} seq={} attempt={} rto_ns={}", .{ conn.id, conn.snd_una, conn.retries, conn.rto_ns }) catch {};
        self.retransmitAt(conn, conn.snd_una);
        self.armTimer(conn, .rto, conn.rto_ns);
    }

    fn onPersist(self: *Engine, conn: *Connection) void {
        if (conn.snd_wnd > 0 or conn.snd_nxt >= conn.sendEnd() or conn.state == .closed) {
            conn.persist_backoff_ns = 0;
            self.output(conn);
            return;
        }
        if (conn.persist_probes >= self.options.timing.data_retries) {
            self.fail(conn, conn.soft_err orelse .timed_out);
            return;
        }
        conn.persist_probes += 1;
        self.world().record("tcp.window_probe conn={} attempt={}", .{ conn.id, conn.persist_probes }) catch {};
        // A probe below the receive window draws a fresh ACK and window.
        self.sendControl(conn, .{ .ack = true }, conn.snd_nxt - 1);
        conn.persist_backoff_ns = self.ceilTick(@min(conn.persist_backoff_ns *| 2, self.options.timing.max_rto_ns));
        self.armTimer(conn, .persist, conn.persist_backoff_ns);
    }

    fn deliverIcmp(self: *Engine, icmp: Icmp) void {
        const conn = self.findConnection(icmp.to, icmp.src, icmp.dst) orelse {
            self.world().record("net.unreachable pkt={} fault={} conn=none", .{ icmp.packet, icmp.fault }) catch {};
            return;
        };
        self.world().record("net.unreachable pkt={} fault={} conn={}", .{ icmp.packet, icmp.fault, conn.id }) catch {};
        if (conn.state == .syn_sent) {
            // Linux aborts a connect on a hard unreachable signal.
            self.fail(conn, .host_unreachable);
            self.reapClosed();
            return;
        }
        conn.soft_err = .host_unreachable;
    }

    fn reapClosed(self: *Engine) void {
        var index: usize = 0;
        while (index < self.connections.count()) {
            const conn = self.connections.values()[index];
            const reap = conn.state == .closed and conn.handle == null and !self.inAcceptQueue(conn);
            if (!reap) {
                index += 1;
                continue;
            }
            if (conn.listener) |listener_id| {
                if (self.listeners.get(listener_id)) |listener| {
                    for (listener.accept_queue.items, 0..) |queued, position| {
                        if (queued == conn.id) {
                            _ = listener.accept_queue.orderedRemove(position);
                            break;
                        }
                    }
                }
            }
            conn.deinit(self.allocator);
            self.connections.orderedRemoveAt(index);
            self.allocator.destroy(conn);
        }
    }

    fn inAcceptQueue(self: *Engine, conn: *const Connection) bool {
        const listener = self.listeners.get(conn.listener orelse return false) orelse return false;
        for (listener.accept_queue.items) |queued| {
            if (queued == conn.id) return true;
        }
        return false;
    }

    fn notify(self: *Engine, kind: Notifier.Kind, handle: u64) void {
        const notifier = self.notifier orelse return;
        notifier.notify(notifier.ptr, kind, handle);
    }

    fn notifyConnection(self: *Engine, conn: *const Connection) void {
        if (conn.handle) |handle| self.notify(.connection, handle);
    }

    // ------------------------------------------------------------------
    // Event loop.

    /// Process every event due at or before now, in time order.
    pub fn pump(self: *Engine) void {
        if (self.pumping) return;
        self.pumping = true;
        defer self.pumping = false;
        const current = self.now();
        while (self.events.peek()) |event| {
            if (event.at > current) break;
            _ = self.events.pop();
            switch (event.kind) {
                .segment => |segment| self.arrive(segment),
                .icmp => |icmp| self.deliverIcmp(icmp),
                .timer => |timer| self.fire(timer),
            }
        }
    }

    fn pumpQuiet(self: *Engine) void {
        self.pump();
    }

    fn eventLive(self: *const Engine, event: Event) bool {
        return switch (event.kind) {
            .segment, .icmp => true,
            .timer => |timer| self.timerLive(timer) != null,
        };
    }

    /// Whether processing `event` can change application-visible state.
    /// Cleanup timers and window probes that will be answered with a zero
    /// window again cannot; the scheduler does not wake for them, so a
    /// system that can only wait on them reports a deadlock.
    fn eventEssential(self: *const Engine, event: Event) bool {
        const timer = switch (event.kind) {
            .segment, .icmp => return true,
            .timer => |timer| timer,
        };
        const conn = self.timerLive(timer) orelse return false;
        return switch (timer.kind) {
            .time_wait, .fin_wait2 => false,
            .persist => self.probeCanProgress(conn),
            .rto, .delayed_ack, .arp => true,
        };
    }

    fn probeCanProgress(self: *const Engine, conn: *const Connection) bool {
        if (self.fabric.down_nodes[conn.host] or self.fabric.down_nodes[conn.peer_host]) return true;
        if (conn.host != conn.peer_host) {
            const there = self.fabric.registry.pathIndex(conn.host, conn.peer_host);
            const back = self.fabric.registry.pathIndex(conn.peer_host, conn.host);
            const registry = self.fabric.registry;
            if (registry.blocks(there) or registry.blocks(back) or registry.holds(there) or registry.holds(back)) return true;
        }
        for (self.connections.values()) |peer| {
            if (peer.host != conn.peer_host) continue;
            if (!sameEndpoint(peer.local, conn.remote) or !sameEndpoint(peer.remote, conn.local)) continue;
            return peer.window() > 0 or peer.state == .closed;
        }
        return true;
    }

    /// Earliest live event strictly after now and at or before `end_ns`.
    pub fn nextEventBeforeOrAt(self: *const Engine, end_ns: Timestamp) ?Timestamp {
        var best: ?Timestamp = null;
        const current = self.fabric.world.now();
        for (self.events.items) |event| {
            if (event.at <= current or event.at > end_ns) continue;
            if (!self.eventLive(event)) continue;
            if (best == null or event.at < best.?) best = event.at;
        }
        return best;
    }

    /// Earliest event the scheduler should wake for.
    pub fn nextEssentialEventAt(self: *const Engine) ?Timestamp {
        var best: ?Timestamp = null;
        const current = self.fabric.world.now();
        for (self.events.items) |event| {
            if (event.at <= current) continue;
            if (best != null and event.at >= best.?) continue;
            if (!self.eventEssential(event)) continue;
            best = event.at;
        }
        return best;
    }

    /// Faults changed: release segments no hold fault covers any longer.
    pub fn faultsChanged(self: *Engine) void {
        var index: usize = 0;
        while (index < self.held.items.len) {
            const segment = self.held.items[index];
            const path = self.fabric.registry.pathIndex(segment.from, segment.to);
            if (self.fabric.registry.holds(path)) {
                index += 1;
                continue;
            }
            _ = self.held.orderedRemove(index);
            self.world().record("net.release pkt={}", .{segment.id}) catch {};
            self.schedule(self.now(), .{ .segment = segment }) catch self.freeSegment(segment);
        }
        self.pump();
    }

    // ------------------------------------------------------------------
    // Inspection.

    pub fn connectionCount(self: *const Engine) usize {
        return self.connections.count();
    }

    pub fn connection(self: *Engine, id: u64) ?*Connection {
        return self.connections.get(id);
    }

    /// Record a `netstat` table of sockets and held packets into the trace.
    pub fn recordNetstat(self: *Engine, reason: []const u8) !void {
        const world_ptr = self.world();
        try world_ptr.record("netstat.begin reason={s} now_ns={} listeners={} connections={} in_flight={} held={}", .{
            reason,
            world_ptr.now(),
            self.listeners.count(),
            self.connections.count(),
            self.inFlightSegments(),
            self.held.items.len,
        });
        for (self.listeners.values()) |listener| {
            try world_ptr.record("netstat.listen sock={} host={} local={f} accept_queue={} backlog={}", .{
                listener.id, listener.host, listener.address, listener.accept_queue.items.len, listener.backlog,
            });
        }
        for (self.connections.values()) |conn| {
            const unsent = conn.sendEnd() -| @max(conn.snd_nxt, conn.send_seq);
            try world_ptr.record("netstat.tcp conn={} host={} state={s} local={f} remote={f} send_q={} unacked={} unsent={} recv_q={} out_of_order={} snd_wnd={} rcv_wnd={} retries={} rto_ns={} owner={s}", .{
                conn.id,
                conn.host,
                conn.state.label(),
                conn.local,
                conn.remote,
                conn.send_buf.items.len,
                conn.snd_nxt - conn.snd_una,
                unsent,
                conn.recv_buf.items.len,
                conn.oooBytes(),
                conn.snd_wnd,
                conn.window(),
                conn.retries,
                conn.rto_ns,
                if (conn.handle != null) "app" else if (conn.listener != null) "accept_queue" else "kernel",
            });
        }
        for (self.fabric.registry.faults.items) |*fault| {
            try world_ptr.record("netstat.fault fault={} kind={s} mode={s} paths={} until_ns={}", .{
                fault.id,
                @tagName(fault.kind),
                @tagName(fault.mode),
                fault.pathCount(),
                fault.until_ns orelse 0,
            });
        }
        try world_ptr.record("netstat.end reason={s}", .{reason});
    }

    fn inFlightSegments(self: *const Engine) usize {
        var count: usize = 0;
        for (self.events.items) |event| {
            if (event.kind == .segment) count += 1;
        }
        return count;
    }
};
