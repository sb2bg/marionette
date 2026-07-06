//! Shared network identifiers, options, faults, and validation.

const clock_module = @import("../clock.zig");
const env_module = @import("../env.zig");
const message_pool_module = @import("../message_pool.zig");

/// Stable simulated node/process identifier.
pub const NodeId = u16;

/// Errors returned by unstable network runtime validation.
pub const NetworkError = error{
    /// The simulation was not configured with a network.
    NetworkUnavailable,
    /// A node/process id is outside the configured topology.
    InvalidNode,
    /// A duration is zero where progress requires a positive interval, not
    /// aligned to the world's tick, or would overflow simulated time.
    InvalidDuration,
    /// A send drop rate has an invalid numerator/denominator pair.
    InvalidRate,
    /// A directed path queue is at capacity.
    EventQueueFull,
};

/// Validate a rate as a network-domain error (`error.InvalidRate`).
pub fn validateRate(rate: env_module.BuggifyRate) NetworkError!void {
    if (rate.denominator == 0) return error.InvalidRate;
    if (rate.numerator > rate.denominator) return error.InvalidRate;
}

/// Fixed topology and per-path capacity for one unstable network instance.
pub const NetworkOptions = struct {
    /// Number of simulated service/replica nodes.
    node_count: usize,
    /// Number of simulated client processes. Client ids follow node ids.
    client_count: usize = 0,
    /// Maximum packets queued on one directed path.
    path_capacity: usize,
};

/// Runtime fault configuration for app-facing network sends.
pub const NetworkFaultOptions = struct {
    drop_rate: env_module.BuggifyRate = .never(),
    min_latency_ns: clock_module.Duration = 0,
    latency_jitter_ns: clock_module.Duration = 0,
    path_clog_rate: env_module.BuggifyRate = .never(),
    path_clog_duration_ns: clock_module.Duration = 0,
    partition_rate: env_module.BuggifyRate = .never(),
    unpartition_rate: env_module.BuggifyRate = .never(),
    partition_stability_min_ns: clock_module.Duration = 0,
    unpartition_stability_min_ns: clock_module.Duration = 0,
};

/// Seeded per-packet drop rate applied at send time, set through
/// `control.network.setLossiness`.
pub const NetworkLossOptions = struct {
    drop_rate: env_module.BuggifyRate = .never(),
};

/// Delivery latency applied to every packet, set through
/// `control.network.setLatency`. Both values must be tick-aligned.
pub const NetworkLatencyOptions = struct {
    /// Base delivery delay in nanoseconds.
    min_latency_ns: clock_module.Duration = 0,
    /// Maximum additional seeded jitter in nanoseconds.
    latency_jitter_ns: clock_module.Duration = 0,
};

/// Seeded automatic path clogging, set through `control.network.setClogs`.
/// A nonzero rate requires a positive tick-aligned duration.
pub const NetworkClogOptions = struct {
    /// Per-tick chance that one directed path clogs.
    path_clog_rate: env_module.BuggifyRate = .never(),
    /// How long an automatic clog holds the path, in nanoseconds.
    path_clog_duration_ns: clock_module.Duration = 0,
};

/// Seeded automatic node-isolating partitions, set through
/// `control.network.setPartitionDynamics` and evolved at `tick`/`runFor`
/// fault boundaries. Stability durations must be tick-aligned.
pub const NetworkPartitionDynamicsOptions = struct {
    /// Per-tick chance that one service node is isolated.
    partition_rate: env_module.BuggifyRate = .never(),
    /// Per-tick chance that an active automatic partition heals.
    unpartition_rate: env_module.BuggifyRate = .never(),
    /// Minimum healed time before the next automatic partition.
    partition_stability_min_ns: clock_module.Duration = 0,
    /// Minimum partitioned time before an automatic heal.
    unpartition_stability_min_ns: clock_module.Duration = 0,
};

/// Runtime topology for a composition-root network simulation.
pub const SimNetworkOptions = struct {
    /// Total simulated processes/nodes.
    nodes: usize,
    /// Prefix of process ids eligible for automatic node-isolating partitions.
    /// Use this when the topology includes client ids that should experience
    /// partitions but should not be selected as the isolated service node.
    /// Defaults to all configured processes when zero.
    // TODO(roadmap item 12): replace this prefix count with an explicit
    // `partitionable_nodes` set before richer topologies depend on it.
    service_nodes: usize = 0,
    /// Maximum packets queued on one directed path.
    path_capacity: usize = 64,
};
/// Default buffer pool sizing for byte endpoints.
pub const default_byte_pool_options: message_pool_module.Options = .{
    .buffers = 64,
    .buffer_size = 64 * 1024,
};
