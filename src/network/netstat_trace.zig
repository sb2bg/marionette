//! Reconstruct a `netstat` table from a trace.
//!
//! A watchdog kills a stalled worker, so its parent cannot ask the network for
//! its sockets. The trace still names every socket's last state and every
//! fault that is still active, which is enough to explain the stall.

const std = @import("std");

const Socket = struct {
    conn: []const u8,
    host: []const u8 = "?",
    state: []const u8 = "?",
    local: []const u8 = "?",
    remote: []const u8 = "?",
};

const Listener = struct {
    sock: []const u8,
    host: []const u8,
    addr: []const u8,
};

const ActiveFault = struct {
    id: []const u8,
    kind: []const u8,
    mode: []const u8,
};

fn field(fields: []const u8, key: []const u8) ?[]const u8 {
    var items = std.mem.splitScalar(u8, fields, ' ');
    while (items.next()) |item| {
        const equals = std.mem.indexOfScalar(u8, item, '=') orelse continue;
        if (std.mem.eql(u8, item[0..equals], key)) return item[equals + 1 ..];
    }
    return null;
}

/// Append `netstat.*` events derived from `trace`, numbered from
/// `first_event`. Returns the number of events written. Writes nothing when
/// the trace carries no `tcp_v1` activity.
pub fn append(allocator: std.mem.Allocator, out: *std.ArrayList(u8), trace: []const u8, first_event: u64) !u64 {
    var sockets: std.ArrayList(Socket) = .empty;
    defer sockets.deinit(allocator);
    var listeners: std.ArrayList(Listener) = .empty;
    defer listeners.deinit(allocator);
    var faults: std.ArrayList(ActiveFault) = .empty;
    defer faults.deinit(allocator);
    var saw_tcp = false;

    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |line| {
        const after_index = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const rest = line[after_index + 1 ..];
        const name_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const name = rest[0..name_end];
        const fields = if (name_end < rest.len) rest[name_end + 1 ..] else "";

        if (std.mem.eql(u8, name, "network.model")) saw_tcp = true;
        if (std.mem.eql(u8, name, "tcp.connect")) {
            try sockets.append(allocator, .{
                .conn = field(fields, "conn") orelse continue,
                .host = field(fields, "host") orelse "?",
                .state = "SYN_SENT",
                .local = field(fields, "src") orelse "?",
                .remote = field(fields, "dst") orelse "?",
            });
        } else if (std.mem.eql(u8, name, "tcp.state")) {
            const conn = field(fields, "conn") orelse continue;
            const state = field(fields, "state") orelse continue;
            if (findSocket(sockets.items, conn)) |socket| {
                socket.state = state;
            } else {
                try sockets.append(allocator, .{
                    .conn = conn,
                    .host = field(fields, "host") orelse "?",
                    .state = state,
                    .local = field(fields, "local") orelse "?",
                    .remote = field(fields, "remote") orelse "?",
                });
            }
        } else if (std.mem.eql(u8, name, "tcp.listen")) {
            try listeners.append(allocator, .{
                .sock = field(fields, "sock") orelse continue,
                .host = field(fields, "host") orelse "?",
                .addr = field(fields, "addr") orelse "?",
            });
        } else if (std.mem.eql(u8, name, "tcp.listen_close")) {
            const sock = field(fields, "sock") orelse continue;
            for (listeners.items, 0..) |listener, index| {
                if (std.mem.eql(u8, listener.sock, sock)) {
                    _ = listeners.orderedRemove(index);
                    break;
                }
            }
        } else if (std.mem.eql(u8, name, "network.fault")) {
            try faults.append(allocator, .{
                .id = field(fields, "fault") orelse continue,
                .kind = field(fields, "kind") orelse "?",
                .mode = field(fields, "mode") orelse "?",
            });
        } else if (std.mem.eql(u8, name, "network.fault_heal")) {
            const id = field(fields, "fault") orelse continue;
            for (faults.items, 0..) |fault, index| {
                if (std.mem.eql(u8, fault.id, id)) {
                    _ = faults.orderedRemove(index);
                    break;
                }
            }
        } else if (std.mem.eql(u8, name, "network.fault_heal_all")) {
            const scope = field(fields, "scope");
            if (scope == null) {
                faults.clearRetainingCapacity();
            } else {
                var index: usize = 0;
                while (index < faults.items.len) {
                    if (!std.mem.eql(u8, faults.items[index].mode, "hold")) {
                        _ = faults.orderedRemove(index);
                    } else index += 1;
                }
            }
        }
    }
    if (!saw_tcp) return 0;

    var event = first_event;
    var live: usize = 0;
    for (sockets.items) |socket| {
        if (!std.mem.eql(u8, socket.state, "CLOSED")) live += 1;
    }
    try out.print(allocator, "event={} netstat.begin reason=watchdog derived=trace listeners={} connections={} faults={}\n", .{ event, listeners.items.len, live, faults.items.len });
    event += 1;
    for (listeners.items) |listener| {
        try out.print(allocator, "event={} netstat.listen sock={s} host={s} local={s}\n", .{ event, listener.sock, listener.host, listener.addr });
        event += 1;
    }
    for (sockets.items) |socket| {
        if (std.mem.eql(u8, socket.state, "CLOSED")) continue;
        try out.print(allocator, "event={} netstat.tcp conn={s} host={s} state={s} local={s} remote={s}\n", .{ event, socket.conn, socket.host, socket.state, socket.local, socket.remote });
        event += 1;
    }
    for (faults.items) |fault| {
        try out.print(allocator, "event={} netstat.fault fault={s} kind={s} mode={s}\n", .{ event, fault.id, fault.kind, fault.mode });
        event += 1;
    }
    try out.print(allocator, "event={} netstat.end reason=watchdog\n", .{event});
    event += 1;
    return event - first_event;
}

fn findSocket(sockets: []Socket, conn: []const u8) ?*Socket {
    for (sockets) |*socket| {
        if (std.mem.eql(u8, socket.conn, conn)) return socket;
    }
    return null;
}

test "netstat_trace: last socket states and active faults survive in the table" {
    const trace =
        \\event=0 network.model semantics=tcp_v1 address_model=per_host_v1 timing=linux mss=1460 send_buffer=1 receive_buffer=1
        \\event=1 tcp.listen sock=1 host=0 addr=10.0.0.1:7000 backlog=128
        \\event=2 tcp.connect conn=2 host=1 src=10.0.0.2:32768 dst=10.0.0.1:7000
        \\event=3 tcp.state conn=3 host=0 state=SYN_RECV sock=1 local=10.0.0.1:7000 remote=10.0.0.2:32768
        \\event=4 tcp.state conn=2 host=1 state=ESTABLISHED
        \\event=5 network.fault fault=1 kind=partition mode=drop paths=2 delay_ns=0 until_ns=0
        \\event=6 network.fault fault=2 kind=cut mode=hold paths=1 delay_ns=0 until_ns=0
        \\event=7 network.fault_heal fault=2 reason=healed
        \\
    ;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const count = try append(std.testing.allocator, &out, trace, 8);
    try std.testing.expectEqual(@as(u64, 6), count);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "event=10 netstat.tcp conn=2 host=1 state=ESTABLISHED local=10.0.0.2:32768 remote=10.0.0.1:7000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "netstat.fault fault=1 kind=partition mode=drop") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "fault=2") == null);
}
