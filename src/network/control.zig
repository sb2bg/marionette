//! Type-erased network fault-control authority.

const std = @import("std");
const clock_module = @import("../clock.zig");
const fault_evolution_module = @import("../fault_evolution.zig");
const faults = @import("faults.zig");
const types = @import("types.zig");
const World = @import("../world.zig").World;

pub const Fault = faults.Fault;

/// Every error the network control can return. The interface has one
/// simulated implementation, so callers get a precise set.
pub const ControlError = types.NetworkError || std.mem.Allocator.Error || @import("../world.zig").TraceError || @import("../world.zig").DecisionError;
pub const FaultOptions = faults.FaultOptions;
pub const DegradeOptions = faults.DegradeOptions;

const NetworkClogOptions = types.NetworkClogOptions;
const NetworkLatencyOptions = types.NetworkLatencyOptions;
const NetworkLossOptions = types.NetworkLossOptions;
const NetworkPartitionDynamicsOptions = types.NetworkPartitionDynamicsOptions;
const NodeId = types.NodeId;

/// Type-erased simulator-control view for network fault orchestration.
pub const AnyNetworkControl = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        set_lossiness: *const fn (*anyopaque, NetworkLossOptions) ControlError!void,
        set_latency: *const fn (*anyopaque, NetworkLatencyOptions) ControlError!void,
        set_clogs: *const fn (*anyopaque, NetworkClogOptions) ControlError!void,
        set_partition_dynamics: *const fn (*anyopaque, NetworkPartitionDynamicsOptions) ControlError!void,
        set_node: *const fn (*anyopaque, NodeId, bool) ControlError!void,
        set_link: *const fn (*anyopaque, NodeId, NodeId, bool) ControlError!void,
        clog: *const fn (*anyopaque, NodeId, NodeId, clock_module.Duration) ControlError!void,
        unclog: *const fn (*anyopaque, NodeId, NodeId) ControlError!void,
        unclog_all: *const fn (*anyopaque) ControlError!void,
        partition: *const fn (*anyopaque, []const NodeId, []const NodeId, FaultOptions) ControlError!Fault,
        isolate: *const fn (*anyopaque, NodeId, FaultOptions) ControlError!Fault,
        cut: *const fn (*anyopaque, NodeId, NodeId, FaultOptions) ControlError!Fault,
        degrade: *const fn (*anyopaque, NodeId, NodeId, DegradeOptions) ControlError!Fault,
        heal_fault: *const fn (*anyopaque, Fault) ControlError!void,
        active_faults: *const fn (*anyopaque) usize,
        add_host_name: *const fn (*anyopaque, []const u8, NodeId) ControlError!void,
        record_netstat: *const fn (*anyopaque, []const u8) ControlError!void,
        next_essential_event_at: *const fn (*anyopaque) ?clock_module.Timestamp,
        semantics: *const fn (*anyopaque) ?types.Semantics,
        heal: *const fn (*anyopaque) ControlError!void,
        heal_links: *const fn (*anyopaque) ControlError!void,
        restore_core_liveness: *const fn (*anyopaque, []const NodeId) ControlError!void,
        evolve_tick_faults: *const fn (*anyopaque) ControlError!void,
        evolve_for: *const fn (*anyopaque, clock_module.Duration) ControlError!void,
        next_fault_boundary_before_or_at: *const fn (*anyopaque, clock_module.Timestamp) ControlError!?clock_module.Timestamp,
        finish_run_for: *const fn (*anyopaque) ControlError!void,
        world: *const fn (*anyopaque) ?*World,
        shared: *const fn (*anyopaque) ?*anyopaque,
    };

    /// Control handle for a simulation without a configured network.
    /// Every fault operation returns `error.NetworkUnavailable`.
    pub fn unavailable() AnyNetworkControl {
        return .{ .ptr = &unavailable_network_control_ctx, .vtable = &unavailable_network_control_vtable };
    }

    /// Set the seeded per-packet drop rate applied at send time. Traced
    /// as `network.lossiness`; drops record `network.drop`.
    pub fn setLossiness(self: AnyNetworkControl, options: NetworkLossOptions) ControlError!void {
        try self.vtable.set_lossiness(self.ptr, options);
    }

    /// Set base delivery latency plus seeded jitter. Values must be
    /// tick-aligned or `error.InvalidDuration` returns. Traced as
    /// `network.latency`.
    pub fn setLatency(self: AnyNetworkControl, options: NetworkLatencyOptions) ControlError!void {
        try self.vtable.set_latency(self.ptr, options);
    }

    /// Set the seeded automatic path-clog rate and duration. Replaces
    /// pending automatic clog schedules. Traced as `network.clog_faults`.
    pub fn setClogs(self: AnyNetworkControl, options: NetworkClogOptions) ControlError!void {
        try self.vtable.set_clogs(self.ptr, options);
    }

    /// Set the seeded automatic node-isolating partition/heal rates.
    /// Dynamics evolve only at `tick`/`runFor` fault boundaries. Traced
    /// as `network.partition_dynamics`.
    pub fn setPartitionDynamics(self: AnyNetworkControl, options: NetworkPartitionDynamicsOptions) ControlError!void {
        try self.vtable.set_partition_dynamics(self.ptr, options);
    }

    /// Mark one simulated node up or down. Packets from or to a down node
    /// are dropped with a trace-visible reason. Traced as `network.node`.
    pub fn setNode(self: AnyNetworkControl, node: NodeId, up: bool) ControlError!void {
        try self.vtable.set_node(self.ptr, node, up);
    }

    /// Enable or disable one directed link. Traced as `network.link`.
    pub fn setLink(self: AnyNetworkControl, from: NodeId, to: NodeId, enabled: bool) ControlError!void {
        try self.vtable.set_link(self.ptr, from, to, enabled);
    }

    /// Clog one directed path until simulated time advances by
    /// `duration_ns` (positive and tick-aligned, or
    /// `error.InvalidDuration`). Queued packets wait; they are not
    /// dropped. Traced as `network.clog`.
    pub fn clog(self: AnyNetworkControl, from: NodeId, to: NodeId, duration_ns: clock_module.Duration) ControlError!void {
        try self.vtable.clog(self.ptr, from, to, duration_ns);
    }

    /// Clear one directed path clog. Traced as `network.unclog`.
    pub fn unclog(self: AnyNetworkControl, from: NodeId, to: NodeId) ControlError!void {
        try self.vtable.unclog(self.ptr, from, to);
    }

    /// Clear every directed path clog. Traced as `network.unclog_all`.
    pub fn unclogAll(self: AnyNetworkControl) ControlError!void {
        try self.vtable.unclog_all(self.ptr);
    }

    /// Cut every directed link crossing between the two groups, in both
    /// directions, and return the fault. Nodes in neither group keep
    /// reaching both sides (a partial partition). Traced as
    /// `network.partition` and, except under `legacy_v0`, `network.fault`.
    pub fn partition(self: AnyNetworkControl, left: []const NodeId, right: []const NodeId, options: FaultOptions) ControlError!Fault {
        return self.vtable.partition(self.ptr, left, right, options);
    }

    /// Cut one node off from every other node, in both directions.
    pub fn isolate(self: AnyNetworkControl, node: NodeId, options: FaultOptions) ControlError!Fault {
        return self.vtable.isolate(self.ptr, node, options);
    }

    /// Disrupt one directed link.
    pub fn cut(self: AnyNetworkControl, from: NodeId, to: NodeId, options: FaultOptions) ControlError!Fault {
        return self.vtable.cut(self.ptr, from, to, options);
    }

    /// Slow one directed link, optionally with seeded loss. `tcp_v1` only.
    pub fn degrade(self: AnyNetworkControl, from: NodeId, to: NodeId, options: DegradeOptions) ControlError!Fault {
        return self.vtable.degrade(self.ptr, from, to, options);
    }

    /// Heal one fault, leaving every other fault in place. Returns
    /// `error.FaultNotActive` when it already healed or expired. Traced as
    /// `network.fault_heal`.
    pub fn healFault(self: AnyNetworkControl, fault: Fault) ControlError!void {
        try self.vtable.heal_fault(self.ptr, fault);
    }

    /// Number of active fault handles.
    pub fn activeFaultCount(self: AnyNetworkControl) usize {
        return self.vtable.active_faults(self.ptr);
    }

    /// Make the simulated DNS resolve `name` to `node`'s addresses.
    /// Every node also resolves as `nodeN`. `tcp_v1` only.
    pub fn addHostName(self: AnyNetworkControl, name: []const u8, node: NodeId) ControlError!void {
        try self.vtable.add_host_name(self.ptr, name, node);
    }

    /// Record a `netstat` table of sockets, held packets, and active
    /// faults into the trace (`netstat.*` events). `tcp_v1` only; a no-op
    /// otherwise.
    pub fn recordNetstat(self: AnyNetworkControl, reason: []const u8) ControlError!void {
        try self.vtable.record_netstat(self.ptr, reason);
    }

    /// Configured network semantics, or null without a network.
    pub fn semantics(self: AnyNetworkControl) ?types.Semantics {
        return self.vtable.semantics(self.ptr);
    }

    /// The node's IPv4 address under `per_host_v1`.
    pub fn hostIp4(node: NodeId, port: u16) @import("std").Io.net.IpAddress {
        return @import("tcp.zig").Engine.hostIp4(node, port);
    }

    /// The node's IPv6 address under `per_host_v1`.
    pub fn hostIp6(node: NodeId, port: u16) @import("std").Io.net.IpAddress {
        return @import("tcp.zig").Engine.hostIp6(node, port);
    }

    /// Re-enable every link, clear every clog, and mark every node up.
    /// Traced as `network.heal`.
    pub fn heal(self: AnyNetworkControl) ControlError!void {
        try self.vtable.heal(self.ptr);
    }

    /// Re-enable every link without changing node up/down state or clogs.
    /// Traced as `network.heal_links`.
    pub fn healLinks(self: AnyNetworkControl) ControlError!void {
        try self.vtable.heal_links(self.ptr);
    }

    /// Re-enable links, clear clogs, and mark nodes up inside the core
    /// only, leaving faults that touch non-core nodes in place. Building
    /// block for the one-shot liveness transition.
    pub fn restoreCoreLiveness(self: AnyNetworkControl, core: []const NodeId) ControlError!void {
        try self.vtable.restore_core_liveness(self.ptr, core);
    }

    /// Return the owning world, or null for the unavailable control.
    pub fn world(self: AnyNetworkControl) ?*World {
        return self.vtable.world(self.ptr);
    }
};

/// Internal adapter used by the composition run loop.
pub const internal = struct {
    pub fn faultEvolutionParticipant(control: AnyNetworkControl) fault_evolution_module.Participant {
        return .{
            .ptr = control.ptr,
            .evolve_at_boundary = control.vtable.evolve_tick_faults,
            .next_boundary_before_or_at = control.vtable.next_fault_boundary_before_or_at,
            .finish_run_for = control.vtable.finish_run_for,
        };
    }

    pub fn nextEssentialEventAt(control: AnyNetworkControl) ?clock_module.Timestamp {
        return control.vtable.next_essential_event_at(control.ptr);
    }
};

var unavailable_network_control_ctx: u8 = 0;

const unavailable_network_control_vtable: AnyNetworkControl.VTable = .{
    .set_lossiness = unavailableControlSetLossiness,
    .set_latency = unavailableControlSetLatency,
    .set_clogs = unavailableControlSetClogs,
    .set_partition_dynamics = unavailableControlSetPartitionDynamics,
    .set_node = unavailableControlSetNode,
    .set_link = unavailableControlSetLink,
    .clog = unavailableControlClog,
    .unclog = unavailableControlUnclog,
    .unclog_all = unavailableControlUnclogAll,
    .partition = unavailableControlPartition,
    .isolate = unavailableControlIsolate,
    .cut = unavailableControlCut,
    .degrade = unavailableControlDegrade,
    .heal_fault = unavailableControlHealFault,
    .active_faults = unavailableControlActiveFaults,
    .add_host_name = unavailableControlAddHostName,
    .record_netstat = unavailableControlRecordNetstat,
    .next_essential_event_at = unavailableControlNextEssentialEventAt,
    .semantics = unavailableControlSemantics,
    .heal = unavailableControlHeal,
    .heal_links = unavailableControlHealLinks,
    .restore_core_liveness = unavailableControlRestoreCoreLiveness,
    .evolve_tick_faults = unavailableControlEvolveTickFaults,
    .evolve_for = unavailableControlEvolveFor,
    .next_fault_boundary_before_or_at = unavailableControlNextFaultBoundaryBeforeOrAt,
    .finish_run_for = unavailableControlFinishRunFor,
    .world = unavailableControlWorld,
    .shared = unavailableControlShared,
};

fn unavailableControlSetLossiness(_: *anyopaque, _: NetworkLossOptions) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetLatency(_: *anyopaque, _: NetworkLatencyOptions) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetClogs(_: *anyopaque, _: NetworkClogOptions) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetPartitionDynamics(_: *anyopaque, _: NetworkPartitionDynamicsOptions) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetNode(_: *anyopaque, _: NodeId, _: bool) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetLink(_: *anyopaque, _: NodeId, _: NodeId, _: bool) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlClog(_: *anyopaque, _: NodeId, _: NodeId, _: clock_module.Duration) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlUnclog(_: *anyopaque, _: NodeId, _: NodeId) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlUnclogAll(_: *anyopaque) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlPartition(_: *anyopaque, _: []const NodeId, _: []const NodeId, _: FaultOptions) ControlError!Fault {
    return error.NetworkUnavailable;
}

fn unavailableControlIsolate(_: *anyopaque, _: NodeId, _: FaultOptions) ControlError!Fault {
    return error.NetworkUnavailable;
}

fn unavailableControlCut(_: *anyopaque, _: NodeId, _: NodeId, _: FaultOptions) ControlError!Fault {
    return error.NetworkUnavailable;
}

fn unavailableControlDegrade(_: *anyopaque, _: NodeId, _: NodeId, _: DegradeOptions) ControlError!Fault {
    return error.NetworkUnavailable;
}

fn unavailableControlHealFault(_: *anyopaque, _: Fault) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlActiveFaults(_: *anyopaque) usize {
    return 0;
}

fn unavailableControlAddHostName(_: *anyopaque, _: []const u8, _: NodeId) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlRecordNetstat(_: *anyopaque, _: []const u8) ControlError!void {}

fn unavailableControlNextEssentialEventAt(_: *anyopaque) ?clock_module.Timestamp {
    return null;
}

fn unavailableControlSemantics(_: *anyopaque) ?types.Semantics {
    return null;
}

fn unavailableControlHeal(_: *anyopaque) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlHealLinks(_: *anyopaque) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlRestoreCoreLiveness(_: *anyopaque, _: []const NodeId) ControlError!void {
    return error.NetworkUnavailable;
}

fn unavailableControlEvolveTickFaults(_: *anyopaque) ControlError!void {}

fn unavailableControlEvolveFor(_: *anyopaque, _: clock_module.Duration) ControlError!void {}

fn unavailableControlNextFaultBoundaryBeforeOrAt(_: *anyopaque, _: clock_module.Timestamp) ControlError!?clock_module.Timestamp {
    return null;
}

fn unavailableControlFinishRunFor(_: *anyopaque) ControlError!void {}

fn unavailableControlWorld(_: *anyopaque) ?*World {
    return null;
}

fn unavailableControlShared(_: *anyopaque) ?*anyopaque {
    return null;
}
