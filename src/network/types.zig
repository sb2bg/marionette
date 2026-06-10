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

pub const NetworkLossOptions = struct {
    drop_rate: env_module.BuggifyRate = .never(),
};

pub const NetworkLatencyOptions = struct {
    min_latency_ns: clock_module.Duration = 0,
    latency_jitter_ns: clock_module.Duration = 0,
};

pub const NetworkClogOptions = struct {
    path_clog_rate: env_module.BuggifyRate = .never(),
    path_clog_duration_ns: clock_module.Duration = 0,
};

pub const NetworkPartitionDynamicsOptions = struct {
    partition_rate: env_module.BuggifyRate = .never(),
    unpartition_rate: env_module.BuggifyRate = .never(),
    partition_stability_min_ns: clock_module.Duration = 0,
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
pub const default_byte_pool_options: message_pool_module.Options = .{
    .buffers = 64,
    .buffer_size = 64 * 1024,
};
