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

- VOPR has tick-evolved automatic partitions and unclogs with stability
  windows; Marionette only has explicit scenario actions plus clog expiration.
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

The current type is:

```zig
const Sim = mar.NetworkSimulation(Payload, .{
    .node_count = 3,
    .client_count = 1,
    .path_capacity = 64,
});
```

`node_count` declares simulated service/replica nodes. `client_count` declares
extra client processes whose ids follow node ids. With the example above,
valid process ids are `0`, `1`, `2`, and `3`; id `3` is the first client.
`path_capacity` is per directed link, not global.

`Payload` is user-owned data. Marionette only schedules and traces the packet
metadata:

```zig
const Payload = struct {
    value: u64,
};

const authorities = try world.simulate(.{});
var sim = try Sim.init(authorities.control);

try sim.control().network.setFaults(.{
    .drop_rate = .percent(20),
    .min_latency_ns = 1_000_000,
    .latency_jitter_ns = 2_000_000,
});
try sim.network().send(0, 1, .{ .value = 42 });
```

Deliverable packets are consumed explicitly:

```zig
while (try sim.network().nextDelivery()) |packet| {
    try apply(packet.payload);
}
```

`nextDelivery` advances simulated time when needed and returns `null` when the
network has no pending work.

This is a low-level primitive for examples and early scheduler work. App-like
code sends and drains through `sim.network()`, while fault orchestration goes
through `sim.control().network`. A future composition-root accessor may wrap
the packet core so application code no longer depends on `NetworkSimulation`
directly.

## Topology

The topology is fixed when the network type is instantiated:

```zig
.node_count = 3,
.client_count = 1,
```

All node-shaped APIs reject ids outside `0..node_count + client_count`.
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
try sim.control().network.setNode(1, false);
try sim.control().network.setNode(1, true);
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
try sim.control().network.setLink(0, 1, false);
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
try sim.control().network.setLink(0, 1, true);
```

## Path Clogging

Clogs are directed path faults. A clogged path keeps its packets queued until
simulated time reaches the clog deadline, while other paths keep delivering:

```zig
try sim.control().network.clog(0, 1, 100 * ns_per_ms);
```

If a packet for `0 -> 1` is ready at `t=10ms` but the path is clogged until
`t=100ms`, `popReady` skips that path and may deliver packets from other paths
first. `nextDeliveryAt` reports the earliest time at which any queued packet
can actually make progress, accounting for active clogs.

Clear one path clog explicitly with:

```zig
try sim.control().network.unclog(0, 1);
```

Clear all active clogs with:

```zig
try sim.control().network.unclogAll();
```

Clogs also expire when simulated time reaches `until_ns`. `popReady` evolves
that deterministic state before selecting a packet as a backstop. Scenario and
scheduler code should move simulated time through `sim.tick()` or
`sim.runFor(...)` so network faults evolve at the same boundary as the clock.

## Partitions

Partitions are expressed as batches of directed link filters. The current
helper disables both directions between two groups:

```zig
const left = [_]mar.NodeId{0};
const right = [_]mar.NodeId{ 1, 2 };
try sim.control().network.partition(&left, &right);
```

This disables `0 -> 1`, `1 -> 0`, `0 -> 2`, and `2 -> 0`, while leaving
traffic inside the right side alone.

Heal all disabled links with:

```zig
try sim.control().network.heal();
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

When using `NetworkSimulation`, prefer:

```zig
try sim.tick();
try sim.runFor(10 * ns_per_ms);
```

over calling `world.tick()` or `world.runFor(...)` directly. The simulation
wrapper advances the world and then evolves network fault state. This mirrors
VOPR's outer simulator tick and keeps future disk/network/crash subsystems
from each needing separate caller-managed ticks.

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
try sim.control().network.setFaults(.{ .drop_rate = .percent(20) });
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
- `network.unclog from={} to={} active={}`
- `network.unclog_all clogged_count={}`
- `network.partition left_count={} right_count={}`
- `network.heal disabled_count={} down_count={} clogged_count={}`
- `network.heal_links disabled_count={}`
- `network.faults drop_rate={}/{} min_latency_ns={} latency_jitter_ns={}`

The payload is not dumped into the core network trace. User code should record
domain-specific payload facts separately when useful, as the replicated
register example does with `register.message`.

## Fault Evolution

Current packet loss is still a send-time decision, and partitions/node state
are explicit scenario actions. Path clogs are time-based: the control plane
sets a clog deadline, and the network evolves that state as simulated time
advances. That is useful, but it is not the final VOPR-style fault scheduler.

Future probabilistic fault evolution must be tick-only. Lazy `popReady`
expiration is acceptable for deterministic clog deadlines because no random
roll is involved; random partition or clog probabilities must not fire from
observation methods, or the random stream would depend on how often user code
polls the network.

The next structural layer should be tick-evolved network state: partitions
start and heal on simulator ticks, clog probabilities fire per path with a
stability floor, and liveness mode can change network defaults for the rest of
a run. The per-link queue topology exists so those faults can be added without
rewriting the packet core again.

The first fault profile should be separate from static topology:

```zig
const faults = mar.NetworkFaultOptions{
    .packet_loss_rate = .percent(1),
    .partition_rate = .percent(1),
    .unpartition_rate = .percent(5),
    .partition_min_ticks = 20,
    .unpartition_min_ticks = 20,
    .path_clog_rate = .percent(1),
    .path_clog_duration_mean_ns = 50 * ns_per_ms,
};
```

Exact names are not committed. The important split is that `NetworkOptions`
describes what exists, while the fault profile describes how the simulator may
perturb it during a run. Random rolls belong in `sim.tick()`, never
`popReady`, `pendingCount`, `nextDeliveryAt`, or other observation methods.

## Current Limits

`UnstableNetwork` does not yet support:

- Replay recording.
- Packet duplication.
- Broadcast.
- Node spawning.
- Probabilistic tick-evolved fault schedules.
- Multiple named buses or a non-generic `World.simulate(...).network(Payload)` accessor.
- Command-aware or user-classified link filters.
- Per-link drop predicates.
- Exponential or profile-selected latency distributions.
- Capacity-overflow policies other than returning `EventQueueFull`.
- Event-by-event scheduler callbacks.
- Human summary rendering.

These are deliberate omissions. The current primitive should prove the
smallest useful packet core before growing.

## Next Step

The next high-value addition before disk is a runtime network fault profile on
top of the existing per-link queues:

1. Add `NetworkFaultOptions` separate from static `NetworkOptions`.
2. Move packet loss defaults from every send call into that profile while still
   allowing per-send overrides for focused examples.
3. Add tick-evolved automatic partitions with stability floors.
4. Add tick-evolved per-path clogs with profile-selected duration.

The app-facing/control split in `network-api.md` still matters, but the packet
core is already close enough to host fault profiles. `UnstableNetwork` remains
a simulator primitive; examples should not teach it as the final production
network surface.
