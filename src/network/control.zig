//! Type-erased network fault-control authority.

const clock_module = @import("../clock.zig");
const fault_evolution_module = @import("../fault_evolution.zig");
const types = @import("types.zig");
const World = @import("../world.zig").World;

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
        set_lossiness: *const fn (*anyopaque, NetworkLossOptions) anyerror!void,
        set_latency: *const fn (*anyopaque, NetworkLatencyOptions) anyerror!void,
        set_clogs: *const fn (*anyopaque, NetworkClogOptions) anyerror!void,
        set_partition_dynamics: *const fn (*anyopaque, NetworkPartitionDynamicsOptions) anyerror!void,
        set_node: *const fn (*anyopaque, NodeId, bool) anyerror!void,
        set_link: *const fn (*anyopaque, NodeId, NodeId, bool) anyerror!void,
        clog: *const fn (*anyopaque, NodeId, NodeId, clock_module.Duration) anyerror!void,
        unclog: *const fn (*anyopaque, NodeId, NodeId) anyerror!void,
        unclog_all: *const fn (*anyopaque) anyerror!void,
        partition: *const fn (*anyopaque, []const NodeId, []const NodeId) anyerror!void,
        heal: *const fn (*anyopaque) anyerror!void,
        heal_links: *const fn (*anyopaque) anyerror!void,
        restore_core_liveness: *const fn (*anyopaque, []const NodeId) anyerror!void,
        evolve_tick_faults: *const fn (*anyopaque) anyerror!void,
        evolve_for: *const fn (*anyopaque, clock_module.Duration) anyerror!void,
        next_fault_boundary_before_or_at: *const fn (*anyopaque, clock_module.Timestamp) anyerror!?clock_module.Timestamp,
        finish_run_for: *const fn (*anyopaque) anyerror!void,
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
    pub fn setLossiness(self: AnyNetworkControl, options: NetworkLossOptions) !void {
        try self.vtable.set_lossiness(self.ptr, options);
    }

    /// Set base delivery latency plus seeded jitter. Values must be
    /// tick-aligned or `error.InvalidDuration` returns. Traced as
    /// `network.latency`.
    pub fn setLatency(self: AnyNetworkControl, options: NetworkLatencyOptions) !void {
        try self.vtable.set_latency(self.ptr, options);
    }

    /// Set the seeded automatic path-clog rate and duration. Replaces
    /// pending automatic clog schedules. Traced as `network.clog_faults`.
    pub fn setClogs(self: AnyNetworkControl, options: NetworkClogOptions) !void {
        try self.vtable.set_clogs(self.ptr, options);
    }

    /// Set the seeded automatic node-isolating partition/heal rates.
    /// Dynamics evolve only at `tick`/`runFor` fault boundaries. Traced
    /// as `network.partition_dynamics`.
    pub fn setPartitionDynamics(self: AnyNetworkControl, options: NetworkPartitionDynamicsOptions) !void {
        try self.vtable.set_partition_dynamics(self.ptr, options);
    }

    /// Mark one simulated node up or down. Packets from or to a down node
    /// are dropped with a trace-visible reason. Traced as `network.node`.
    pub fn setNode(self: AnyNetworkControl, node: NodeId, up: bool) !void {
        try self.vtable.set_node(self.ptr, node, up);
    }

    /// Enable or disable one directed link. Traced as `network.link`.
    pub fn setLink(self: AnyNetworkControl, from: NodeId, to: NodeId, enabled: bool) !void {
        try self.vtable.set_link(self.ptr, from, to, enabled);
    }

    /// Clog one directed path until simulated time advances by
    /// `duration_ns` (positive and tick-aligned, or
    /// `error.InvalidDuration`). Queued packets wait; they are not
    /// dropped. Traced as `network.clog`.
    pub fn clog(self: AnyNetworkControl, from: NodeId, to: NodeId, duration_ns: clock_module.Duration) !void {
        try self.vtable.clog(self.ptr, from, to, duration_ns);
    }

    /// Clear one directed path clog. Traced as `network.unclog`.
    pub fn unclog(self: AnyNetworkControl, from: NodeId, to: NodeId) !void {
        try self.vtable.unclog(self.ptr, from, to);
    }

    /// Clear every directed path clog. Traced as `network.unclog_all`.
    pub fn unclogAll(self: AnyNetworkControl) !void {
        try self.vtable.unclog_all(self.ptr);
    }

    /// Disable every directed link crossing between the two groups, in
    /// both directions. Traced as `network.partition`.
    pub fn partition(self: AnyNetworkControl, left: []const NodeId, right: []const NodeId) !void {
        try self.vtable.partition(self.ptr, left, right);
    }

    /// Re-enable every link, clear every clog, and mark every node up.
    /// Traced as `network.heal`.
    pub fn heal(self: AnyNetworkControl) !void {
        try self.vtable.heal(self.ptr);
    }

    /// Re-enable every link without changing node up/down state or clogs.
    /// Traced as `network.heal_links`.
    pub fn healLinks(self: AnyNetworkControl) !void {
        try self.vtable.heal_links(self.ptr);
    }

    /// Re-enable links, clear clogs, and mark nodes up inside the core
    /// only, leaving faults that touch non-core nodes in place. Building
    /// block for the one-shot liveness transition.
    pub fn restoreCoreLiveness(self: AnyNetworkControl, core: []const NodeId) !void {
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

fn unavailableControlSetLossiness(_: *anyopaque, _: NetworkLossOptions) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetLatency(_: *anyopaque, _: NetworkLatencyOptions) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetClogs(_: *anyopaque, _: NetworkClogOptions) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetPartitionDynamics(_: *anyopaque, _: NetworkPartitionDynamicsOptions) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetNode(_: *anyopaque, _: NodeId, _: bool) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetLink(_: *anyopaque, _: NodeId, _: NodeId, _: bool) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlClog(_: *anyopaque, _: NodeId, _: NodeId, _: clock_module.Duration) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlUnclog(_: *anyopaque, _: NodeId, _: NodeId) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlUnclogAll(_: *anyopaque) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlPartition(_: *anyopaque, _: []const NodeId, _: []const NodeId) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlHeal(_: *anyopaque) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlHealLinks(_: *anyopaque) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlRestoreCoreLiveness(_: *anyopaque, _: []const NodeId) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlEvolveTickFaults(_: *anyopaque) anyerror!void {}

fn unavailableControlEvolveFor(_: *anyopaque, _: clock_module.Duration) anyerror!void {}

fn unavailableControlNextFaultBoundaryBeforeOrAt(_: *anyopaque, _: clock_module.Timestamp) anyerror!?clock_module.Timestamp {
    return null;
}

fn unavailableControlFinishRunFor(_: *anyopaque) anyerror!void {}

fn unavailableControlWorld(_: *anyopaque) ?*World {
    return null;
}

fn unavailableControlShared(_: *anyopaque) ?*anyopaque {
    return null;
}
