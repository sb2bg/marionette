//! Shared network identifiers, options, faults, and validation.

const std = @import("std");

const clock_module = @import("../clock.zig");
const env_module = @import("../env.zig");

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
    /// The network options name an unsupported combination of semantics
    /// and address model.
    InvalidNetworkModel,
    /// The fault mode is not supported by the configured network semantics.
    UnsupportedFaultMode,
    /// The fault handle names a fault that already healed.
    FaultNotActive,
};

/// Network semantics version. Capsules record it, and the replay identity
/// carries `network_semantic_version`, so a capsule never replays under a
/// different model.
pub const Semantics = enum {
    /// The pre-0.9 pull model: delivery waits for readers, faults become
    /// immediate errors, and close and kill reach peers through shared state.
    /// Deprecated: retained for one release so recorded evidence and unported
    /// harnesses keep running; 0.10 removes it.
    legacy_v0,
    /// TCP-lite over a push-based fabric: handshake, cumulative ACKs,
    /// receive windows, timed retransmission with backoff, and FIN and RST on
    /// the wire. A fault by itself produces silence.
    tcp_v1,
};

/// How simulated hosts own addresses and ports.
pub const AddressModel = enum {
    /// One port namespace for the whole world; any node may bind any IP.
    shared_v0,
    /// Each host owns `10.0.0.(node + 1)` and `fd00::(node + 1)`, loopback,
    /// its own port table, and its own ephemeral range. Binding another
    /// host's address fails with `AddressUnavailable`, and `accept` reports
    /// the client's real address.
    per_host_v1,
};

/// Timer profile for `tcp_v1`.
pub const TimingProfile = enum {
    /// Linux defaults: 1 s SYN RTO with 6 retries (connect gives up after
    /// 127 s), 200 ms minimum RTO, 15 data retries, 40 ms delayed ACK.
    linux,
    /// Every Linux interval divided by 100, for long-horizon scenarios.
    compressed,
};

/// Version of the network model's observable semantics. Bump when replaying
/// the same decisions under the same options would change behavior.
pub const network_semantic_version: u32 = 2;

/// Per-socket buffer sizes for `tcp_v1`.
pub const TcpOptions = struct {
    send_buffer_bytes: usize = 64 * 1024,
    receive_buffer_bytes: usize = 64 * 1024,
    /// Maximum segment payload.
    mss: usize = 1460,
};

/// Validate a rate as a network-domain error (`error.InvalidRate`).
pub fn validateRate(rate: env_module.BuggifyRate) NetworkError!void {
    if (rate.denominator == 0) return error.InvalidRate;
    if (rate.numerator > rate.denominator) return error.InvalidRate;
}

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
    service_nodes: usize = 0,
    /// Maximum packets queued on one directed path (`legacy_v0` streams
    /// and typed endpoints).
    path_capacity: usize = 64,
    /// Network semantics. See `Semantics`.
    semantics: Semantics = default_semantics,
    /// Address model; null selects the semantics' native model
    /// (`shared_v0` for `legacy_v0`, `per_host_v1` for `tcp_v1`).
    address_model: ?AddressModel = null,
    /// Timer profile for `tcp_v1`.
    timing: TimingProfile = .linux,
    /// Socket buffers for `tcp_v1`.
    tcp: TcpOptions = .{},
    /// `network_semantic_version` the options were recorded under. Capsules
    /// carry it; replay rejects a capsule whose version differs. Leave it at
    /// its default.
    model_version: u32 = network_semantic_version,

    pub const default_semantics: Semantics = .tcp_v1;

    pub fn resolvedAddressModel(self: SimNetworkOptions) AddressModel {
        return self.address_model orelse switch (self.semantics) {
            .legacy_v0 => .shared_v0,
            .tcp_v1 => .per_host_v1,
        };
    }

    pub fn validateModel(self: SimNetworkOptions) NetworkError!void {
        if (self.semantics == .legacy_v0 and self.resolvedAddressModel() != .shared_v0) return error.InvalidNetworkModel;
        if (self.semantics == .tcp_v1) {
            if (self.tcp.mss == 0 or self.tcp.send_buffer_bytes == 0 or self.tcp.receive_buffer_bytes == 0)
                return error.InvalidNetworkModel;
        }
    }

    /// Capsules written before 0.9 have no model fields; they parse as
    /// `legacy_v0`. Fields equal to the legacy defaults are omitted on
    /// encode so legacy capsules keep their bytes.
    pub fn jsonStringify(self: SimNetworkOptions, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("nodes");
        try writer.write(self.nodes);
        try writer.objectField("service_nodes");
        try writer.write(self.service_nodes);
        try writer.objectField("path_capacity");
        try writer.write(self.path_capacity);
        if (self.semantics != .legacy_v0) {
            try writer.objectField("semantics");
            try writer.write(self.semantics);
        }
        if (self.address_model) |model| {
            try writer.objectField("address_model");
            try writer.write(model);
        }
        if (self.semantics != .legacy_v0 or self.timing != .linux) {
            try writer.objectField("timing");
            try writer.write(self.timing);
        }
        if (self.semantics != .legacy_v0) {
            try writer.objectField("tcp");
            try writer.write(self.tcp);
            try writer.objectField("model_version");
            try writer.write(self.model_version);
        }
        try writer.endObject();
    }

    const Wire = struct {
        nodes: usize,
        service_nodes: usize = 0,
        path_capacity: usize = 64,
        semantics: Semantics = .legacy_v0,
        address_model: ?AddressModel = null,
        timing: TimingProfile = .linux,
        tcp: TcpOptions = .{},
        model_version: u32 = network_semantic_version,
    };

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !SimNetworkOptions {
        const wire = try std.json.innerParse(Wire, allocator, source, options);
        return fromWire(wire);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !SimNetworkOptions {
        const wire = try std.json.innerParseFromValue(Wire, allocator, source, options);
        return fromWire(wire);
    }

    fn fromWire(wire: Wire) SimNetworkOptions {
        return .{
            .nodes = wire.nodes,
            .service_nodes = wire.service_nodes,
            .path_capacity = wire.path_capacity,
            .semantics = wire.semantics,
            .address_model = wire.address_model,
            .timing = wire.timing,
            .tcp = wire.tcp,
            .model_version = wire.model_version,
        };
    }
};
