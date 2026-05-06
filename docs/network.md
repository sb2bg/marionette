# Network Model

This is a design note for Marionette's current unstable network simulation
work. It is not the final public network API yet.

For the intended production/simulation API split, see
[Network API Direction](network-api.md).

The goal is a deterministic network authority that can make distributed
failures replayable from a seed. The first slice is intentionally small:
messages can be delayed, dropped, queued, filtered by directed link state,
clogged by directed path, partitioned, healed, stopped, restarted, and
delivered in a stable order. Replay recording, node spawning, and the final
scheduler API come later.

## VOPR Comparison

TigerBeetle's VOPR network is built around `PacketSimulator`, a deterministic
packet core with one link for every directed source-target path. Each link owns
a queue, a command filter, an optional packet drop predicate, an optional
recording filter, and path clog state. Global packet simulator options include
node/client counts, seed, latency distribution, packet loss, packet replay,
automatic partition settings, partition stability, unpartition stability,
per-path capacity, and path clog probability/duration.

The portable lessons for Marionette are:

- Treat the network as simulator-owned machinery, not real sockets.
- Keep packet send/delivery separate from simulator-control faults.
- Queue packets per directed path, not in one global network bucket.
- Give every packet a replay-visible identity.
- Make latency, loss, replay, clogs, and partitions seeded simulator decisions.
- Evolve random network faults only from the simulator tick.
- Trace sends, drops, deliveries, and state changes separately.
- Layer advanced faults on top of a small packet core.

The current `UnstableNetwork` already follows the core shape: fixed topology,
per-directed-path queues, path-local capacity, stable packet ids, seeded
latency/drop decisions, explicit link filters, explicit partitions, path clogs,
node up/down state, and delivery order by `(deliver_at, packet_id)`.

The main differences are deliberate:

- VOPR has broader tick-evolved automatic fault scheduling; Marionette now has
  a narrow version for per-path clogs and node-isolating partitions.
- VOPR can replay packets and record selected command classes for later
  replay; Marionette has whole-run seed replay but no packet-sequence replay.
- VOPR has command-aware link filters and optional per-link drop predicates;
  Marionette is payload-generic and does not know user protocol commands yet.
- VOPR uses an exponential latency model with a minimum; Marionette currently
  uses uniform tick-aligned jitter.
- VOPR can randomly drop an already queued packet when a path is over
  capacity; Marionette returns queue-capacity errors from the packet core.
- VOPR's automatic partitions are replica/node-focused; Marionette's manual
  `partition` helper can target any configured process, including clients.

Marionette should not copy TigerBeetle's full harness. TigerBeetle has a
production protocol, message pools, client/replica process identities, command
classes, replay recording, and liveness-specific modes. Marionette needs the
same discipline in a generic API, not the same product-specific surface.

## Current API

The current app-facing type is `mar.Network(Payload)`. Simulation setup
creates the backing topology and returns typed handles from the composition
root:

```zig
const sim = try world.simulate(.{ .network = .{
    .nodes = 4,
    .service_nodes = 3,
    .path_capacity = 64,
} });
const net = try sim.network(Payload);
```

`nodes` declares the total simulated process ids. With the example above,
valid process ids are `0`, `1`, `2`, and `3`. `path_capacity` is per directed
link, not global. `service_nodes` declares the prefix of process ids eligible
for automatic node-isolating partitions; when omitted or zero, all processes
are eligible.

`Payload` is user-owned data. Marionette only schedules and traces the packet
metadata:

```zig
const Payload = struct {
    value: u64,
};

try sim.control.network.setFaults(.{
    .drop_rate = .percent(20),
    .min_latency_ns = 1_000_000,
    .latency_jitter_ns = 2_000_000,
});
try net.send(0, 1, .{ .value = 42 });
```

Deliverable packets are consumed explicitly:

```zig
while (try net.nextDelivery()) |packet| {
    try apply(packet.payload);
}
```

`nextDelivery` advances simulated time when needed and returns `null` when the
network has no pending work.

Application-shaped code sends and drains through the typed handle, while fault
orchestration goes through `sim.control.network`. `mar.UnstableNetwork` remains
the lower-level packet-core primitive for focused simulator work.

## Topology

The topology is fixed when simulation is created:

```zig
.nodes = 4,
```

All node-shaped APIs reject ids outside `0..nodes`.
That gives the simulator a known universe for partitions, per-link queues,
node state, and future liveness cores. It also makes invalid topology use
return `InvalidNode` instead of silently creating new processes by accident.

Each directed path owns its own queue and enabled/disabled state. `popReady`
scans the heads of all path queues and picks the ready packet with the lowest
`(deliver_at, packet_id)`. The scan is acceptable for Phase 0 capacities; a
later scheduler can add an index over active paths without changing the
per-link model needed for clogging and path-local capacity.

## Node State

Nodes are up by default. Mark a simulated process down or up with:

```zig
try sim.control.network.setNode(1, false);
try sim.control.network.setNode(1, true);
```

A down source cannot submit new packets. `send` still consumes a stable packet
id and records:

```text
network.drop id=<id> from=1 to=2 reason=source_down
```

A down destination drops ready packets at delivery time:

```text
network.drop id=<id> from=0 to=1 reason=destination_down
```

Queued packets are not removed when a node goes down. If the destination is
restarted before delivery time, the packet can still be delivered. That keeps
process state as another deterministic delivery gate, like directed link
state, without trying to model full process-local storage or restart behavior
yet.

## Link Filters

Links are directed. A disabled link drops ready packets at delivery time:

```zig
try sim.control.network.setLink(0, 1, false);
```

If a packet from node `0` to node `1` is already queued when the link is
disabled, it remains queued. When it becomes ready, `popReady` drops it and
records:

```text
network.drop id=<id> from=0 to=1 reason=link_disabled
```

This mirrors the VOPR-style idea that the network's link state at delivery can
decide whether an in-flight packet makes it through.

Re-enable a directed link with:

```zig
try sim.control.network.setLink(0, 1, true);
```

## Path Clogging

Clogs are directed path faults. A clogged path keeps its packets queued until
simulated time reaches the clog deadline, while other paths keep delivering:

```zig
try sim.control.network.clog(0, 1, 100 * ns_per_ms);
```

If a packet for `0 -> 1` is ready at `t=10ms` but the path is clogged until
`t=100ms`, `popReady` skips that path and may deliver packets from other paths
first. `nextDeliveryAt` reports the earliest time at which any queued packet
can actually make progress, accounting for active clogs.

Clear one path clog explicitly with:

```zig
try sim.control.network.unclog(0, 1);
```

Clear all active clogs with:

```zig
try sim.control.network.unclogAll();
```

Clogs also expire when simulated time reaches `until_ns`. `popReady` evolves
that deterministic state before selecting a packet as a backstop. Scenario and
scheduler code should move simulated time through `sim.control.tick()` or
`sim.control.runFor(...)` so network faults evolve at the same boundary as the clock.

## Partitions

Partitions are expressed as batches of directed link filters. The current
helper disables both directions between two groups:

```zig
const left = [_]mar.NodeId{0};
const right = [_]mar.NodeId{ 1, 2 };
try sim.control.network.partition(&left, &right);
```

This disables `0 -> 1`, `1 -> 0`, `0 -> 2`, and `2 -> 0`, while leaving
traffic inside the right side alone.

Heal all disabled links with:

```zig
try sim.control.network.heal();
```

`heal` restores default network state by re-enabling links and marking nodes
up, and it clears active clogs. Use `healLinks` when a scenario needs to clear
link filters without changing node state or path clogs.

This is deliberately simple. Later network work can add asymmetric partitions,
automatic partition schedules, and liveness modes.

## Ordering

Packets are ordered by:

1. `deliver_at`
2. `packet_id`

That is the same basic tie-breaker discipline Marionette uses elsewhere:
simulated time first, stable id second. Pointers, host thread scheduling, hash
map iteration order, and wall-clock time must never decide delivery order.

## Time

Network latency is measured in nanoseconds, but it must align with the
world's tick size. Phase 0 simulated time advances in whole ticks, so
`UnstableNetwork` rejects `min_latency_ns` and `latency_jitter_ns` values that
are not whole multiples of the world's tick.

When using composition-root simulation, prefer:

```zig
try sim.control.tick();
try sim.control.runFor(10 * ns_per_ms);
```

over calling `world.tick()` or `world.runFor(...)` directly. Simulation control
advances the world and then evolves network fault state. This mirrors VOPR's
outer simulator tick and keeps future disk/network/crash subsystems from each
needing separate caller-managed ticks.

The current latency model is uniform integer jitter over whole ticks:

```text
latency = min_latency_ns + random(0..latency_jitter_ns)
```

where the random jitter is tick-aligned.

Later versions may add distributions such as exponential latency. The first
priority is deterministic replay and clear traces, not realism.

## Drops

Every `send` consumes a packet id. If the drop decision fires, Marionette
records `network.drop` and does not enqueue the payload.

The current drop model uses `BuggifyRate`:

```zig
try sim.control.network.setFaults(.{ .drop_rate = .percent(20) });
```

This keeps the API consistent with BUGGIFY without making packet drops into
opaque user behavior. Marionette owns the random decision; user code owns the
payload and protocol semantics.

## Trace Events

Current network trace events:

- `network.send id={} from={} to={} deliver_at={} latency_ns={}`
- `network.drop id={} from={} to={} drop_rate={}/{} roll={} reason=send_drop`
- `network.drop id={} from={} to={} reason=source_down`
- `network.drop id={} from={} to={} reason=destination_down`
- `network.drop id={} from={} to={} reason=link_disabled`
- `network.deliver id={} from={} to={} now_ns={}`
- `network.node node={} up={}`
- `network.link from={} to={} enabled={}`
- `network.clog from={} to={} duration_ns={} until_ns={}`
- `network.clog from={} to={} duration_ns={} until_ns={} automatic=true`
- `network.unclog from={} to={} active={}`
- `network.unclog_all clogged_count={}`
- `network.partition left_count={} right_count={}`
- `network.auto_partition node={} isolated_count=1 connected_count={}`
- `network.auto_heal node={}`
- `network.heal disabled_count={} down_count={} clogged_count={}`
- `network.heal_links disabled_count={}`
- `network.faults drop_rate={}/{} min_latency_ns={} latency_jitter_ns={} path_clog_rate={}/{} path_clog_duration_ns={} partition_rate={}/{} unpartition_rate={}/{} partition_stability_min_ns={} unpartition_stability_min_ns={}`

The payload is not dumped into the core network trace. User code should record
domain-specific payload facts separately when useful, as the replicated
register example does with `register.message`.

## Fault Evolution

Packet loss is still a send-time decision. Probabilistic path clogs and
automatic partitions are tick-evolved decisions: random rolls happen only when
simulation control advances time with `sim.control.tick()` or
`sim.control.runFor(...)`. Lazy `popReady` expiration remains only for
deterministic clog deadlines; random partition or clog probabilities do not
fire from observation methods.

The runtime fault profile is separate from static topology:

```zig
const faults = mar.NetworkFaultOptions{
    .drop_rate = .percent(1),
    .min_latency_ns = 1 * ns_per_ms,
    .latency_jitter_ns = 2 * ns_per_ms,
    .path_clog_rate = .percent(1),
    .path_clog_duration_ns = 50 * ns_per_ms,
    .partition_rate = .percent(1),
    .unpartition_rate = .percent(5),
    .partition_stability_min_ns = 20 * ns_per_ms,
    .unpartition_stability_min_ns = 20 * ns_per_ms,
};
```

`SimNetworkOptions` describes what exists; `NetworkFaultOptions` describes how
the simulator may perturb it during a run. Automatic partitioning currently
isolates one random service node from every other configured process and heals
only after the unpartition stability floor has elapsed and the unpartition
roll fires. Explicit `partition`, `heal`, `setLink`, and `clog` calls remain
immediate scenario actions.

## Current Limits

`UnstableNetwork` does not yet support:

- Replay recording.
- Packet duplication.
- Broadcast.
- Node spawning.
- Multiple named buses or bus registry.
- Command-aware or user-classified link filters.
- Per-link drop predicates.
- Exponential or profile-selected latency distributions.
- Capacity-overflow policies other than returning `EventQueueFull`.
- Event-by-event scheduler callbacks.
- Human summary rendering.

These are deliberate omissions. The current primitive should prove the
smallest useful packet core before growing.

## Next Step

The app-facing/control split in `network-api.md` still matters. The remaining
network work is liveness-oriented: replay recording, duplicate/broadcast
semantics, richer latency distributions, and named bus composition.
`UnstableNetwork` remains a simulator primitive; examples should not teach it
as the final production network surface.
