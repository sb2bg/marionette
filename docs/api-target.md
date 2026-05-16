# API Target Spec

This is the current target shape for Marionette examples and public API. It is
intentionally narrower than a full production networking stack; see
[Network API Direction](network-api.md) for the remaining socket-adapter work.

## Core Principles

Application code receives `Env` and any typed handles it needs, such as
`Endpoint(Message)`. Test harnesses receive `Control` and use it to inject
faults.

Harnesses own simulator control. Production-shaped code does not import or hold
`Control`, `World`, or packet-core types.

`runCase(opts) !RunReport` is the primitive for stateful scenarios.
`expectPass`, `expectFuzz`, and `expectFailure` are assertive test helpers
built on top of it.

Faults are configuration, not per-call parameters. Network loss, latency,
clogs, and automatic partition dynamics are set through focused
`control.network` methods such as `setLossiness(...)`, `setLatency(...)`,
`setClogs(...)`, and `setPartitionDynamics(...)`; disk faults are set through
`control.disk.setFaults(...)`.

Empty options are not options. Disk crash and restart calls are `crash()` and
`restart()`.

## Current Library Shape

```zig
pub fn runCase(opts: anytype) !RunReport;
pub fn expectPass(opts: anytype) !void;
pub fn expectFuzz(opts: anytype) !void;
pub fn expectFailure(opts: anytype) !void;

pub const Env = struct {
    disk: Disk,
    clock: EnvClock,
    random: EnvRandom,
    tracer: Tracer,
    pub fn io(self: Env) std.Io;
    pub fn recorder(self: Env) Recorder;
    pub fn record(self: Env, comptime fmt: []const u8, args: anytype) !void;
};

pub const Control = SimControl;

pub fn Endpoint(comptime Message: type) type;
pub fn CodecTransport(comptime Codec: type) type;

pub const codec = struct {
    pub const bytes = ...;
    pub fn fixed(comptime Send: type, comptime Recv: type) type;
};

pub const SimNetworkOptions = struct {
    nodes: usize,
    service_nodes: usize = 0,
    path_capacity: usize = 64,
};

pub const Sim = struct {
    env: Env,
    control: Control,
    pub fn endpoint(self: Sim, comptime Message: type, node: NodeId) !Endpoint(Message);
    pub fn endpoints(self: Sim, comptime Message: type, comptime count: usize, first_node: NodeId) ![count]Endpoint(Message);
    pub fn byteEndpoint(self: Sim, node: NodeId) !ByteEndpoint;
    pub fn byteEndpoints(self: Sim, comptime count: usize, first_node: NodeId) ![count]ByteEndpoint;
};

pub const Production = struct {
    pub fn env(self: *Production) Env;
    pub fn endpoint(self: *Production, comptime Message: type, opts: ProductionEndpointOptions) !Endpoint(Message);
    pub fn endpoints(self: *Production, comptime Message: type, comptime count: usize, opts: ProductionEndpointsOptions) ![count]Endpoint(Message);
    pub fn byteEndpoint(self: *Production, opts: ProductionEndpointOptions) !ByteEndpoint;
    pub fn byteEndpoints(self: *Production, comptime count: usize, opts: ProductionEndpointsOptions) ![count]ByteEndpoint;
};
```

`runCase` accepts optional `.deinit = State.deinit` for state that owns
non-world resources. The older positional `runWithState*` helpers are internal
implementation details, not part of the public teaching surface.

`Env.io()` is the forward-compatible `std.Io` accessor. Production envs return
the host `std.Io` supplied to `Production.init`; simulation envs return
Marionette's current deterministic backend. That backend supports deterministic
clock and random operations today, synchronous `async`, and closed failures for
filesystem/network/process operations that are not routed through the simulator
yet. See [Marionette as Deterministic std.Io](std-io-direction.md).

`Env.recorder()` returns a narrow structured recording capability. Code that is
otherwise production-shaped should prefer accepting `std.Io` plus
`mar.Recorder` instead of accepting all of `Env` only to emit trace events.

The current network endpoint is obtained from the composition root:

```zig
const sim = try world.simulate(.{ .network = .{ .nodes = 4, .path_capacity = 64 } });
var replica_0 = Replica.init(sim.env, try sim.endpoint(Message, 0));
```

The design keeps `Env` non-generic and passes `Endpoint(Message)` as a sibling
handle. `Production.endpoint(Message, opts)` currently provides a local
in-process production-shaped endpoint with declared peer topology for
same-process parity tests. `Production.byteEndpoint(opts)` uses that same local
adapter unless `opts.listen` is set, in which case it uses the first
socket-backed loopback transport slice.

`ByteEndpoint` is the byte-oriented sibling for libraries that want Marionette
behind their own protocol API. `send(to, bytes)` copies borrowed bytes before
returning; `acquire(len)` plus `sendMessage(to, message)` transfers an acquired
pool buffer without a second copy; `receive()` returns a releasable message that
the caller must release.

`ByteTransport` is the preferred small wrapper for protocol adapters that do
not want to expose message-pool ownership. It wraps `ByteEndpoint` with
`send(to, bytes)`, `receive()` plus `deinit`, and an optional builder returned
by `acquire(len)`.

`CodecTransport(Codec)` is the preferred typed wrapper for protocol adapters.
The codec declares `Send`, `Recv`, `recv_lifetime`, `encode`, and `decode`.
Received handles own the underlying bytes until `deinit`; borrowed codecs can
opt into `take(allocator)` by providing `cloneRecv`.

## Example Shape

Network-shaped examples should split into:

- A production-shaped type that holds `env`, typed node endpoints, and app
  state.
- A test-only `Harness` that owns the production-shaped type, `control`, and
  any simulation owner needed for handle lifetime.
- Free check functions that inspect `*const Harness` or the app state through
  the harness.

Application sends look like:

```zig
try endpoint.send(to, message);
while (try endpoint.receive()) |envelope| {
    try apply(envelope.from, envelope.message);
}
```

Scenario faults look like:

```zig
try harness.control.network.setLossiness(.{ .drop_rate = .percent(20) });
try harness.control.network.partition(&isolated, &majority);
try harness.control.network.heal();
```

The replicated-register example is the canonical network-shaped reference.
