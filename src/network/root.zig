//! Deterministic network subsystem root.
//!
//! Assembles public handles and options from the focused endpoint, control,
//! and simulation modules in this directory.

const control = @import("control.zig");
const endpoint = @import("endpoint.zig");
const packet_core = @import("packet_core.zig");
const sim = @import("sim.zig");
const types = @import("types.zig");

pub const AnyNetworkControl = control.AnyNetworkControl;
pub const ByteEndpoint = endpoint.ByteEndpoint;
pub const Endpoint = endpoint.Endpoint;
pub const NetworkClogOptions = types.NetworkClogOptions;
pub const NetworkError = types.NetworkError;
pub const NetworkLatencyOptions = types.NetworkLatencyOptions;
pub const NetworkLossOptions = types.NetworkLossOptions;
pub const NetworkOptions = types.NetworkOptions;
pub const NetworkPartitionDynamicsOptions = types.NetworkPartitionDynamicsOptions;
pub const NodeId = types.NodeId;
pub const SimNetworkOptions = types.SimNetworkOptions;
pub const default_byte_pool_options = types.default_byte_pool_options;

/// Internal composition hooks for Marionette's world, I/O backend, and
/// production environment.
pub const internal = struct {
    pub const NetworkFaultOptions = types.NetworkFaultOptions;
    pub const NetworkSimulation = packet_core.NetworkSimulation;
    pub const SimByteDropReason = sim.SimByteDropReason;
    pub const SimByteDroppedEnvelope = sim.SimByteDroppedEnvelope;
    pub const SimByteReceiveResult = sim.SimByteReceiveResult;
    pub const SimByteSendResult = sim.SimByteSendResult;
    pub const UnstableNetwork = packet_core.UnstableNetwork;

    pub const byteEndpointFromControl = sim.byteEndpointFromControl;
    pub const discardStreamFramesFromControl = sim.discardStreamFramesFromControl;
    pub const endpointFromControl = sim.endpointFromControl;
    pub const faultEvolutionParticipantFromControl = control.internal.faultEvolutionParticipant;
    pub const initSimControl = sim.initSimControl;
    pub const nextStreamDeliveryAtForControl = sim.nextStreamDeliveryAtForControl;
    pub const processCountFromControl = sim.processCountFromControl;
    pub const sendStreamBytesFromControl = sim.sendStreamBytesFromControl;
};

test {
    _ = @import("tests.zig");
}
