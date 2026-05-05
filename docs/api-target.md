# API Target Spec

This is the current target shape for Marionette examples and public API. It is
intentionally narrower than a full production networking stack; see
[Network API Direction](network-api.md) for the remaining socket-adapter work.

## Core Principles

Application code receives `Env` and any typed handles it needs, such as
`Network(Payload)`. Test harnesses receive `Control` and use it to inject
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

pub fn Network(comptime Payload: type) type;

pub const SimNetworkOptions = struct {
    nodes: usize,
    path_capacity: usize = 64,
};

pub const Sim = struct {
    env: Env,
    control: Control,
    pub fn network(self: Sim, comptime Payload: type) !Network(Payload);
};

pub const Production = struct {
    pub fn env(self: *Production) Env;
    pub fn network(self: *Production, comptime Payload: type) !Network(Payload);
};
```

The current network handle is obtained from the composition root:

```zig
const sim = try world.simulate(.{ .network = .{ .nodes = 4, .path_capacity = 64 } });
var replicas = Replicas.init(sim.env, try sim.network(MessagePayload));
```

The design keeps `Env` non-generic and passes `Network(Payload)` as a sibling
handle. `Production.network(Payload)` currently provides a local in-process
production-shaped handle for parity tests; a real socket adapter is still
future work.

## Example Shape

Network-shaped examples should split into:

- A production-shaped type that holds `env`, a typed network handle, and app
  state.
- A test-only `Harness` that owns the production-shaped type, `control`, and
  any simulation owner needed for handle lifetime.
- Free check functions that inspect `*const Harness` or the app state through
  the harness.

Application sends look like:

```zig
try net.send(from, to, payload);
while (try net.nextDelivery()) |packet| {
    try apply(packet);
}
```

Scenario faults look like:

```zig
try harness.control.network.setFaults(.{ .drop_rate = .percent(20) });
try harness.control.network.partition(&isolated, &majority);
try harness.control.network.heal();
```

The replicated-register example is the canonical network-shaped reference.
