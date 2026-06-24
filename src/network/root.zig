//! Deterministic network subsystem root.
//!
//! Assembles public handles and options from the focused endpoint, control,
//! simulation, transport, and production modules in this directory.

const byte_transport = @import("byte_transport.zig");
const codec_transport = @import("codec_transport.zig");
const control = @import("control.zig");
const endpoint = @import("endpoint.zig");
const packet_core = @import("packet_core.zig");
const production = @import("production.zig");
const sim = @import("sim.zig");
const types = @import("types.zig");

pub const AnyNetworkControl = control.AnyNetworkControl;
pub const ByteEndpoint = endpoint.ByteEndpoint;
pub const ByteTransport = byte_transport.ByteTransport;
pub const CodecRecvLifetime = codec_transport.CodecRecvLifetime;
pub const CodecTransport = codec_transport.CodecTransport;
pub const Endpoint = endpoint.Endpoint;
pub const NetworkClogOptions = types.NetworkClogOptions;
pub const NetworkError = types.NetworkError;
pub const NetworkLatencyOptions = types.NetworkLatencyOptions;
pub const NetworkLossOptions = types.NetworkLossOptions;
pub const NetworkOptions = types.NetworkOptions;
pub const NetworkPartitionDynamicsOptions = types.NetworkPartitionDynamicsOptions;
pub const NodeId = types.NodeId;
pub const ProductionByteEndpointError = production.ProductionByteEndpointError;
pub const ProductionEndpointOptions = production.ProductionEndpointOptions;
pub const ProductionEndpointsOptions = production.ProductionEndpointsOptions;
pub const ProductionNetworkError = production.ProductionNetworkError;
pub const ProductionPeer = production.ProductionPeer;
pub const SimNetworkOptions = types.SimNetworkOptions;
pub const default_byte_pool_options = types.default_byte_pool_options;
pub const default_codec_encode_buffer_size = codec_transport.default_codec_encode_buffer_size;

/// Internal composition hooks for Marionette's world, I/O backend, and
/// production environment.
pub const internal = struct {
    pub const NetworkFaultOptions = types.NetworkFaultOptions;
    pub const NetworkSimulation = packet_core.NetworkSimulation;
    pub const ProductionNetworkEntry = production.ProductionNetworkEntry;
    pub const ProductionNetworkTeardown = production.ProductionNetworkTeardown;
    pub const SimByteDropReason = sim.SimByteDropReason;
    pub const SimByteDroppedEnvelope = sim.SimByteDroppedEnvelope;
    pub const SimByteReceiveResult = sim.SimByteReceiveResult;
    pub const SimByteSendResult = sim.SimByteSendResult;
    pub const UnstableNetwork = packet_core.UnstableNetwork;

    pub const byteEndpointFromControl = sim.byteEndpointFromControl;
    pub const endpointFromControl = sim.endpointFromControl;
    pub const faultEvolutionParticipantFromControl = control.internal.faultEvolutionParticipant;
    pub const initSimControl = sim.initSimControl;
    pub const nextStreamDeliveryAtForControl = sim.nextStreamDeliveryAtForControl;
    pub const processCountFromControl = sim.processCountFromControl;
    pub const productionByteEndpoint = production.productionByteEndpoint;
    pub const productionEndpoint = production.productionEndpoint;
    pub const receiveReadyStreamEventFromControl = sim.receiveReadyStreamEventFromControl;
    pub const sendStreamBytesFromControl = sim.sendStreamBytesFromControl;
};

test {
    _ = @import("tests.zig");
}
