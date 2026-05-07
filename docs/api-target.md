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

Faults are configuration, not per-call parameters. Network drops and latency
are set through `control.network.setFaults(...)`; disk faults are set through
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
    pub fn record(self: Env, comptime fmt: []const u8, args: anytype) !void;
};

pub const Control = SimControl;

pub fn Endpoint(comptime Message: type) type;
pub const Network = Endpoint; // compatibility alias

pub const SimNetworkOptions = struct {
    nodes: usize,
    service_nodes: usize = 0,
    path_capacity: usize = 64,
};

pub const Sim = struct {
    env: Env,
    control: Control,
    pub fn endpoint(self: Sim, comptime Message: type, node: NodeId) !Endpoint(Message);
    pub fn endpointRange(self: Sim, comptime Message: type, comptime count: usize, first_node: NodeId) ![count]Endpoint(Message);
};

pub const Production = struct {
    pub fn env(self: *Production) Env;
    pub fn endpoint(self: *Production, comptime Message: type, node: NodeId) !Endpoint(Message);
    pub fn endpointRange(self: *Production, comptime Message: type, comptime count: usize, first_node: NodeId) ![count]Endpoint(Message);
};
```

`runCase` accepts optional `.deinit = State.deinit` for state that owns
non-world resources. The older positional `runWithState*` helpers are internal
implementation details, not part of the public teaching surface.

The current network endpoint is obtained from the composition root:

```zig
const sim = try world.simulate(.{ .network = .{ .nodes = 4, .path_capacity = 64 } });
var replica_0 = Replica.init(sim.env, try sim.endpoint(Message, 0));
```

The design keeps `Env` non-generic and passes `Endpoint(Message)` as a sibling
handle. `Production.endpoint(Message, node)` currently provides a local in-process
production-shaped endpoint for same-process parity tests; it is not a
cross-process transport. A real socket adapter is still future work.

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
try harness.control.network.setFaults(.{ .drop_rate = .percent(20) });
try harness.control.network.partition(&isolated, &majority);
try harness.control.network.heal();
```

The replicated-register example is the canonical network-shaped reference.
