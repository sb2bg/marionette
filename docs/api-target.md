# API Target Spec

This is the current target shape for Marionette examples and public API. It is
intentionally narrower than a full production networking stack. `std.Io.net`
is the literal same-code network seam; experimental typed endpoints model
protocol behavior above an application-owned transport seam. See [Network API
Direction](network-api.md).

## Core Principles

Production-shaped code should receive `std.Io`, a root `std.Io.Dir`, and any
small stable capabilities it actually needs, such as `Recorder`. Experimental
protocol models may receive `Endpoint(Message)` in simulation. `Env` is the
composition-root bundle for the stable environment handles.

Simulation tests should usually use `SimCase(App)`: the app initializer
receives `Sim`, app state lives at `case.app`, and scenarios use
`case.control()` to inject faults. Production-shaped code does not import or
hold `Control`, `World`, or packet-core types.

`runSimCase(opts) !RunReport` is the primary stateful simulation runner.
`expectSimPass`, `expectSimFuzz`, and `expectSimFailure` are assertive test
helpers built on top of it. Harnesses with genuinely custom state drive
`World` directly.

Faults are configuration, not per-call parameters. Network loss, latency,
clogs, and automatic partition dynamics are set through focused
`control.network` methods such as `setLossiness(...)`, `setLatency(...)`,
`setClogs(...)`, and `setPartitionDynamics(...)`; disk faults are set through
`control.disk.setFaults(...)`.

Empty options are not options. Disk crash and restart calls are `crash()` and
`restart()`.

## Current Library Shape

```zig
pub fn SimCase(comptime App: type) type;
pub fn runSimCase(opts: anytype) !RunReport;
pub fn expectSimPass(opts: anytype) !void;
pub fn expectSimFuzz(opts: anytype) !void;
pub fn expectSimFailure(opts: anytype) !void;

pub const Env = struct {
    io_backend: std.Io,
    disk: Disk,
    clock: EnvClock,
    random: EnvRandom,
    tracer: Tracer,
    buggify_enabled: bool,
    pub fn io(self: Env) std.Io;
    pub fn recorder(self: Env) Recorder;
    pub fn record(self: Env, comptime fmt: []const u8, args: anytype) !void;
};

pub const Control = ...; // simulator-control capability bundle
pub const ProcessLifecycle = struct {
    ptr: *anyopaque,
    on_kill: ?*const fn (*anyopaque) void = null,
    restart: *const fn (*anyopaque, Env) anyerror!void,
};

/// Experimental message-modeling surface; not a wire-parity contract.
pub fn Endpoint(comptime Message: type) type;

pub const SimNetworkOptions = struct {
    nodes: usize,
    service_nodes: usize = 0,
    path_capacity: usize = 64,
};

pub const Sim = struct {
    env: Env,
    control: Control,
    pub fn envForNode(self: Sim, node: NodeId) !Env;
    pub fn registerProcess(self: Sim, node: NodeId, lifecycle: ProcessLifecycle) !void;
    pub fn killProcess(self: Sim, node: NodeId) !void;
    pub fn restartProcess(self: Sim, node: NodeId) !void;
    pub fn endpoint(self: Sim, comptime Message: type, node: NodeId) !Endpoint(Message);
    pub fn endpoints(self: Sim, comptime Message: type, comptime count: usize, first_node: NodeId) ![count]Endpoint(Message);
};

pub const Production = struct {
    pub fn env(self: *Production) Env;
};
```

`SimCase(App)` automatically calls `app.deinit()` when `App` defines it.

`Env.io()` is the app-facing `std.Io` accessor. Production envs return the host
`std.Io` supplied to `Production.init`; simulation envs return Marionette's
current deterministic backend. Use `sim.envForNode(node).io()` when separate
`std.Io.net` participants should run as distinct logical processes. That
backend supports deterministic
clock, sleep, random, `randomSecure`, scheduler-backed `Io.async` /
`Io.concurrent` / await, scheduler-backed `Io.Group`, immediate non-blocking
`Io.Queue` operations, and an
in-memory TCP stream subset for `std.Io.net`. Cooperative cancellation is
delivered at the supported futex, sleep, and network suspension points.
It also supports a directory-aware file subset over `SimDisk`:
`Dir.createFile`, `Dir.openFile`, `Dir.statFile`, `Dir.access`, positional and
streaming file reads and writes, `File.length`, `File.stat`, `File.setLength`,
`File.sync`, `File.close`, `Dir.deleteFile`, `Dir.rename`, directory
create/open/stat/iteration, and advisory locks. Streaming cursor state is per
open file handle and advances only by bytes actually transferred. Full
filesystem behavior, process operations, datagrams, DNS, and real external
network access still fail closed. See
[Marionette as Deterministic std.Io](std-io-direction.md).

`Env.recorder()` returns a narrow structured recording capability. Code that is
otherwise production-shaped should prefer accepting `std.Io` plus
`mar.Recorder` instead of accepting all of `Env` only to emit trace events.

The current network endpoint is obtained from the composition root:

```zig
const sim = try world.simulate(.{ .network = .{ .nodes = 4, .path_capacity = 64 } });
var replica_0 = Replica.init(sim.env.io(), sim.env.recorder(), try sim.endpoint(Message, 0));
```

For stream-oriented code, prefer a node-scoped env:

```zig
const server_env = try sim.envForNode(0);
var server = try Server.init(server_env.io(), server_env.recorder());
```

The design keeps `Env` non-generic and passes `Endpoint(Message)` as a sibling
simulation handle. This endpoint is an experimental protocol-modeling tool,
not a promise that production serialization or transport code is exercised.
Production-shaped socket code should take `std.Io` and use `std.Io.net`.
Message-oriented applications should own their transport interface and adapt
it to a Marionette endpoint in tests until a real SUT justifies a shared public
message-transport contract. The deprecated production endpoint adapters and
redundant public `ByteEndpoint` facade were removed in 0.6.

## Example Shape

Network-shaped examples should split into:

- A protocol/state-machine type that holds the narrow message seam it needs and
  no simulator-control authority.
- `SimCase(App)`, where `init(sim: Sim)` wires endpoints into the app and
  scenarios use `case.control()` for simulator-only authority.
- Free check functions that inspect `*const SimCase(App)` or the app state
  through `case.app`.

Application sends look like:

```zig
try endpoint.send(to, message);
while (try endpoint.receive()) |envelope| {
    try apply(envelope.from, envelope.message);
}
```

Scenario faults look like:

```zig
try case.control().network.setLossiness(.{ .drop_rate = .percent(20) });
try case.control().network.partition(&isolated, &majority);
try case.control().network.heal();
```

The replicated-register example is the canonical network-shaped reference.
