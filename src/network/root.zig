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
pub const Endpoint = endpoint.Endpoint;
pub const NetworkClogOptions = types.NetworkClogOptions;
pub const NetworkError = types.NetworkError;
pub const NetworkLatencyOptions = types.NetworkLatencyOptions;
pub const NetworkLossOptions = types.NetworkLossOptions;
pub const NetworkOptions = types.NetworkOptions;
pub const NetworkPartitionDynamicsOptions = types.NetworkPartitionDynamicsOptions;
pub const NodeId = types.NodeId;
pub const SimNetworkOptions = types.SimNetworkOptions;

/// Internal composition hooks for Marionette's world, I/O backend, and
/// production environment.
pub const internal = struct {
    pub const NetworkFaultOptions = types.NetworkFaultOptions;
    pub const NetworkSimulation = packet_core.NetworkSimulation;
    pub const SimByteDropReason = sim.SimByteDropReason;
    pub const SimByteSendResult = sim.SimByteSendResult;
    pub const SimProbeResult = sim.SimProbeResult;
    pub const UnstableNetwork = packet_core.UnstableNetwork;

    pub const discardStreamFramesFromControl = sim.discardStreamFramesFromControl;
    pub const endpointFromControl = sim.endpointFromControl;
    pub const faultEvolutionParticipantFromControl = control.internal.faultEvolutionParticipant;
    pub const initSimControl = sim.initSimControl;
    pub const nextStreamDeliveryAtForControl = sim.nextStreamDeliveryAtForControl;
    pub const commitReadyStreamEventFromControl = sim.commitReadyStreamEventFromControl;
    pub const peekReadyStreamEventFromControl = sim.peekReadyStreamEventFromControl;
    pub const processCountFromControl = sim.processCountFromControl;
    pub const streamPathStateFromControl = sim.streamPathStateFromControl;
    pub const sendStreamBytesFromControl = sim.sendStreamBytesFromControl;
    pub const sendStreamProbeFromControl = sim.sendStreamProbeFromControl;
    pub const commitReadyStreamProbeFromControl = sim.commitReadyStreamProbeFromControl;
    pub const discardStreamPacketFromControl = sim.discardStreamPacketFromControl;
    pub const streamProbeReadyAtFromControl = sim.streamProbeReadyAtFromControl;
    pub const streamLiveBuffersFromControl = sim.streamLiveBuffersFromControl;
};

test {
    _ = @import("tests.zig");
}
