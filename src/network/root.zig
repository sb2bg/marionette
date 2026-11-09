//! Deterministic network subsystem root.
//!
//! Assembles public handles and options from the focused endpoint, control,
//! and simulation modules in this directory.

const control = @import("control.zig");
const endpoint = @import("endpoint.zig");
const faults = @import("faults.zig");
const sim = @import("sim.zig");
const tcp = @import("tcp.zig");
const types = @import("types.zig");

pub const AnyNetworkControl = control.AnyNetworkControl;
pub const AddressModel = types.AddressModel;
pub const DegradeOptions = faults.DegradeOptions;
pub const Fault = faults.Fault;
pub const FaultKind = faults.FaultKind;
pub const FaultMode = faults.FaultMode;
pub const FaultOptions = faults.FaultOptions;
pub const Semantics = types.Semantics;
pub const TcpOptions = types.TcpOptions;
pub const TimingProfile = types.TimingProfile;
pub const network_semantic_version = types.network_semantic_version;
pub const Endpoint = endpoint.Endpoint;
pub const NetworkClogOptions = types.NetworkClogOptions;
pub const NetworkError = types.NetworkError;
pub const NetworkLatencyOptions = types.NetworkLatencyOptions;
pub const NetworkLossOptions = types.NetworkLossOptions;
pub const NetworkPartitionDynamicsOptions = types.NetworkPartitionDynamicsOptions;
pub const NodeId = types.NodeId;
pub const SimNetworkOptions = types.SimNetworkOptions;

/// Internal composition hooks for Marionette's world, I/O backend, and
/// production environment.
pub const internal = struct {
    pub const NetworkFaultOptions = types.NetworkFaultOptions;
    pub const SimByteDropReason = sim.SimByteDropReason;
    pub const SimByteSendResult = sim.SimByteSendResult;
    pub const SimProbeDropReason = sim.SimProbeDropReason;
    pub const SimProbeResult = sim.SimProbeResult;
    pub const StreamWaitObserver = sim.StreamWaitObserver;

    pub const discardStreamFramesFromControl = sim.discardStreamFramesFromControl;
    pub const endpointFromControl = sim.endpointFromControl;
    pub const faultEvolutionParticipantFromControl = control.internal.faultEvolutionParticipant;
    pub const initSimControl = sim.initSimControl;
    pub const nextStreamDeliveryAtForControl = sim.nextStreamDeliveryAtForControl;
    pub const commitReadyStreamEventFromControl = sim.commitReadyStreamEventFromControl;
    pub const peekReadyStreamEventFromControl = sim.peekReadyStreamEventFromControl;
    pub const processCountFromControl = sim.processCountFromControl;
    pub const tcpEngineFromControl = sim.tcpEngineFromControl;
    pub const attachTcpNotifierFromControl = sim.attachTcpNotifierFromControl;
    pub const nextEssentialEventAtFromControl = control.internal.nextEssentialEventAt;
    pub const TcpEngine = tcp.Engine;
    pub const TcpNotifier = tcp.Notifier;
    pub const tcp_ephemeral_port_min = tcp.ephemeral_port_min;
    pub const streamPathStateFromControl = sim.streamPathStateFromControl;
    pub const sendStreamBytesFromControl = sim.sendStreamBytesFromControl;
    pub const sendStreamProbeFromControl = sim.sendStreamProbeFromControl;
    pub const commitReadyStreamProbeFromControl = sim.commitReadyStreamProbeFromControl;
    pub const attachStreamWaitObserverFromControl = sim.attachStreamWaitObserverFromControl;
    pub const discardStreamPacketFromControl = sim.discardStreamPacketFromControl;
    pub const streamProbeReadyAtFromControl = sim.streamProbeReadyAtFromControl;
    pub const streamLiveBuffersFromControl = sim.streamLiveBuffersFromControl;
    pub const streamQueuedPacketsFromControl = sim.streamQueuedPacketsFromControl;
};

test {
    _ = @import("tests.zig");
    _ = @import("faults.zig");
    _ = @import("tcp.zig");
}
