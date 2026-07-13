//! Marionette: deterministic I/O and simulation testing for Zig.
//!
//! Public API entry point.

const std = @import("std");

const allocation_module = @import("allocation.zig");
const clock_module = @import("clock.zig");
const disk_module = @import("disk/root.zig");
const env_module = @import("env.zig");
const fault_module = @import("fault.zig");
const fiber_module = @import("fiber.zig");
const io_module = @import("io/root.zig");
const network_module = @import("network/root.zig");
const profile_module = @import("profile.zig");
const run_module = @import("run.zig");
const seed_module = @import("seed.zig");
const trace_summary_module = @import("trace_summary.zig");

test {
    _ = allocation_module;
    _ = fault_module;
    _ = fiber_module;
    _ = profile_module;
}

/// Duration in nanoseconds.
pub const Duration = clock_module.Duration;

/// Deterministic fake clock advanced explicitly by tests.
pub const SimClock = clock_module.SimClock;

/// Timestamp in nanoseconds.
pub const Timestamp = clock_module.Timestamp;

/// Stable simulated node/process identifier.
pub const NodeId = network_module.NodeId;

/// Errors returned by deterministic network runtime validation.
pub const NetworkError = network_module.NetworkError;

/// Default simulated tick size in nanoseconds.
pub const default_tick_ns = clock_module.default_tick_ns;

/// App-facing disk capability.
pub const Disk = disk_module.Disk;

/// Simulator-control disk capability.
pub const DiskControl = disk_module.DiskControl;

/// Deterministic in-memory disk simulator.
pub const SimDisk = disk_module.SimDisk;

/// Production disk adapter backed by a real root directory.
pub const RealDisk = disk_module.RealDisk;

/// Configuration for one deterministic disk simulator.
pub const DiskOptions = disk_module.DiskOptions;

/// Fault rates and corruption controls for one deterministic disk simulator.
pub const DiskFaultOptions = disk_module.DiskFaultOptions;

/// Errors returned by deterministic disk operations.
pub const DiskError = disk_module.DiskError;

/// Concrete app-facing environment capability bundle.
pub const Env = env_module.Env;

/// Production capability composition root.
pub const Production = env_module.Production;

/// App-facing clock capability.
pub const EnvClock = env_module.Clock;

/// Errors returned by clock capabilities.
pub const ClockError = env_module.ClockError;

/// App-facing random capability.
pub const EnvRandom = env_module.Random;

/// Errors returned by random capabilities.
pub const EnvRandomError = env_module.RandomError;

/// App-facing trace capability.
pub const Tracer = env_module.Tracer;

/// Narrow structured recording capability for `std.Io`-shaped code.
pub const Recorder = env_module.Recorder;

/// Errors returned by trace capabilities.
pub const TracerError = env_module.TracerError;

/// Simulator-control capability bundle.
pub const Control = env_module.SimControl;

/// App and control views returned by `World.simulate`.
pub const Sim = @import("world.zig").World.Simulation;

/// Type-erased logical-process lifecycle callbacks for simulation restart.
pub const ProcessLifecycle = @import("world.zig").ProcessLifecycle;

/// Simulator-control process capability.
pub const ProcessControl = env_module.ProcessControl;

/// Runtime process crash/restart fault configuration.
pub const ProcessDynamicsOptions = env_module.ProcessDynamicsOptions;

/// Probability that a BUGGIFY hook fires in simulation.
pub const BuggifyRate = fault_module.BuggifyRate;

/// Errors returned by BUGGIFY runtime validation.
pub const BuggifyError = fault_module.BuggifyError;

/// Runtime allocation-fault configuration.
pub const AllocationFaultOptions = env_module.AllocationFaultOptions;

/// Address-free allocation counters exposed to harnesses.
pub const AllocationStats = env_module.AllocationStats;

/// Simulator-control allocation capability.
pub const AllocationControl = env_module.AllocationControl;

/// Seeded deterministic random number generator.
pub const Random = @import("random.zig").Random;

/// Deterministic simulation engine state.
pub const World = @import("world.zig").World;

/// Fixed topology and per-path capacity for one network simulation.
pub const NetworkOptions = network_module.NetworkOptions;

/// Runtime network loss configuration.
pub const NetworkLossOptions = network_module.NetworkLossOptions;

/// Runtime network latency configuration.
pub const NetworkLatencyOptions = network_module.NetworkLatencyOptions;

/// Runtime network path-clog configuration.
pub const NetworkClogOptions = network_module.NetworkClogOptions;

/// Runtime automatic partition and heal dynamics.
pub const NetworkPartitionDynamicsOptions = network_module.NetworkPartitionDynamicsOptions;

/// Runtime topology for a composition-root network simulation.
pub const SimNetworkOptions = network_module.SimNetworkOptions;

/// Typed app-facing process endpoint.
pub const Endpoint = network_module.Endpoint;

/// App-facing byte endpoint with explicit message ownership.
pub const ByteEndpoint = network_module.ByteEndpoint;

/// Default byte endpoint pool sizing.
pub const default_byte_pool_options = network_module.default_byte_pool_options;

/// Simulator-control network capability.
pub const NetworkControl = network_module.AnyNetworkControl;

/// Named simulation profile expansion helpers.
pub const SimProfile = profile_module.SimProfile;

/// Namespace for profile helpers.
pub const profile = profile_module;

/// Configuration for `run`.
pub const RunOptions = run_module.RunOptions;

/// Replay-visible typed attribute attached to a run.
pub const RunAttribute = run_module.RunAttribute;

/// Replay-visible scalar attribute value.
pub const RunAttributeValue = run_module.RunAttributeValue;

/// Build one replay-visible typed attribute from a scalar value.
pub const runAttribute = run_module.runAttribute;

/// Named scenario check run by `run`.
pub const Check = run_module.Check;

/// Named scenario check over user-owned scenario state.
pub const StateCheck = run_module.StateCheck;

/// Successful deterministic scenario result.
pub const RunResult = run_module.RunResult;

/// Data-bearing scenario failure.
pub const RunFailure = run_module.RunFailure;

/// Failure kind captured by the runner.
pub const RunFailureKind = run_module.RunFailureKind;

/// Result of `run`: either a verified replay or a failure report.
pub const RunReport = run_module.RunReport;

/// Errors returned by the deterministic scenario runner itself.
pub const RunError = run_module.RunError;

/// Errors returned while writing deterministic trace records.
pub const TraceError = run_module.TraceError;

/// One structured trace field written by `World.recordFields`.
pub const TraceField = @import("world.zig").TraceField;

/// Replay-safe scalar trace value.
pub const TraceValue = @import("world.zig").TraceValue;

/// Build one structured trace field.
pub const traceField = @import("world.zig").traceField;

/// Run a scenario twice with the same seed and compare traces.
pub const run = run_module.run;

/// Standard simulation scenario state wrapper.
pub const SimCase = run_module.SimCase;

/// Run a simulation case through the struct-config runner.
pub const runSimCase = run_module.runSimCase;

/// Expect a simulation case to pass.
pub const expectSimPass = run_module.expectSimPass;

/// Expect a simulation case to fail.
pub const expectSimFailure = run_module.expectSimFailure;

/// Expect a trace to contain a needle, printing the tail on failure.
pub const expectTraceContains = run_module.expectTraceContains;

/// Expect a simulation case to pass over many seeds.
pub const expectSimFuzz = run_module.expectSimFuzz;

/// Errors returned by expectation helpers.
pub const ExpectRunError = run_module.ExpectRunError;

/// Errors returned while parsing a user-supplied seed.
pub const SeedParseError = seed_module.SeedParseError;

/// Parse a decimal seed or 40-character Git hash.
pub const parseSeed = seed_module.parseSeed;

/// Owned deterministic summary of one Marionette trace.
pub const Summary = trace_summary_module.Summary;

/// Errors returned while summarizing a trace.
pub const TraceSummaryError = trace_summary_module.TraceSummaryError;

/// Build an owned summary from line-oriented trace bytes.
pub const summarize = trace_summary_module.summarize;

test "public roots hide internal wiring" {
    const public_api = @This();

    try std.testing.expect(!@hasDecl(public_api, "MessagePool"));
    try std.testing.expect(!@hasDecl(public_api, "NetworkFrame"));

    try std.testing.expect(!@hasDecl(public_api, "SimIo"));
    try std.testing.expect(!@hasField(public_api.Sim, "io_runtime"));
    try std.testing.expect(!@hasField(public_api.Sim, "process_supervisor"));

    try std.testing.expect(!@hasDecl(io_module, "Backend"));
    try std.testing.expect(!@hasDecl(io_module, "ProcessRuntime"));
    try std.testing.expect(!@hasDecl(io_module, "TaskRuntime"));
    try std.testing.expect(!@hasDecl(io_module, "TaskControl"));
    try std.testing.expect(!@hasDecl(io_module, "FutexWaitSet"));

    try std.testing.expect(!@hasDecl(network_module, "NetworkSimulation"));
    try std.testing.expect(!@hasDecl(network_module, "UnstableNetwork"));
    try std.testing.expect(!@hasDecl(network_module, "ProductionNetworkEntry"));
    try std.testing.expect(!@hasDecl(network_module, "initSimControl"));
    try std.testing.expect(!@hasDecl(network_module, "sendStreamBytesFromControl"));
}

test {
    _ = @import("disk/root.zig");
    _ = @import("env.zig");
    _ = @import("message_pool.zig");
    _ = @import("network/root.zig");
    _ = @import("network/frame.zig");
    _ = @import("run.zig");
    _ = @import("run_types.zig");
    _ = @import("scheduler.zig");
    _ = @import("seed.zig");
    _ = @import("tidy.zig");
    _ = @import("trace_summary.zig");
}
