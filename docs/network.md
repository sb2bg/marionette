# Network Model

This is a design note for Marionette's current unstable network simulation
work. It is not the final public network API yet.

The goal is a deterministic network authority that can make distributed
failures replayable from a seed. The first slice is intentionally small:
messages can be delayed, dropped, queued, filtered by directed link state,
partitioned, healed, stopped, restarted, and delivered in a stable order.
Replay recording, path clogging, node spawning, and the final scheduler API
come later.

## VOPR Lessons

TigerBeetle's VOPR network is built around a packet simulator. The important
portable lessons for Marionette are:

- Treat the network as simulator-owned machinery, not real sockets.
- Give every packet a stable id.
- Queue packets per deterministic ordering, not host scheduling order.
- Make latency and packet loss seeded simulator decisions.
- Trace sends, drops, and deliveries separately.
- Keep more advanced fault modes layered on top of a small packet core.

Marionette should not copy TigerBeetle's full harness. TigerBeetle has a
production protocol, message pools, client/replica process identities, replay
recording, partitions, clogging, and liveness-specific modes. Marionette needs
the same shape in spirit, but with a smaller generic API.

## Current API

The current type is:

```zig
const Network = mar.UnstableNetwork(Payload, 64);
```

`Payload` is user-owned data. Marionette only schedules and traces the packet
metadata:

```zig
const Payload = struct {
    value: u64,
};

var network = Network.init();
try network.send(world, 0, 1, .{ .value = 42 }, .{
    .drop_rate = .percent(20),
    .min_latency_ns = 1_000_000,
    .latency_jitter_ns = 2_000_000,
});
```

Ready packets are consumed explicitly:

```zig
while (try network.popReady(world)) |packet| {
    try apply(packet.payload);
}
```

For examples that just need to drive all pending network work, use
`drainUntilIdle`:

```zig
try network.drainUntilIdle(world, context, deliver);
```

The callback receives each delivered packet. The helper advances simulated time
to the next queued packet and keeps running until the queue is empty. The
callback may enqueue more packets.

This is a low-level primitive for examples and early scheduler work. A future
`SimulationEnv.network()` or node-scoped authority may wrap it.

## Node State

Nodes are up by default. Mark a simulated process down or up with:

```zig
try network.setNode(world, 1, false);
try network.setNode(world, 1, true);
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
try network.setLink(world, 0, 1, false);
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
try network.setLink(world, 0, 1, true);
```

## Partitions

Partitions are expressed as batches of directed link filters. The current
helper disables both directions between two groups:

```zig
const left = [_]mar.NodeId{0};
const right = [_]mar.NodeId{ 1, 2 };
try network.partition(world, &left, &right);
```

This disables `0 -> 1`, `1 -> 0`, `0 -> 2`, and `2 -> 0`, while leaving
traffic inside the right side alone.

Heal all disabled links with:

```zig
try network.heal(world);
```

This is deliberately simple. Later network work can add asymmetric partitions,
automatic partition schedules, liveness modes, and explicit node up/down
state.

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
`UnstableNetwork` asserts that `min_latency_ns` and `latency_jitter_ns` are
whole multiples of the world's tick.

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
.drop_rate = .percent(20)
```

This keeps the API consistent with BUGGIFY without making packet drops into
opaque user behavior. Marionette owns the random decision; user code owns the
payload and protocol semantics.

## Trace Events

Current network trace events:

- `network.send id={} from={} to={} deliver_at={} latency_ns={}`
- `network.drop id={} from={} to={} drop_rate={}/{} roll={}`
- `network.drop id={} from={} to={} reason=source_down`
- `network.drop id={} from={} to={} reason=destination_down`
- `network.drop id={} from={} to={} reason=link_disabled`
- `network.deliver id={} from={} to={} now_ns={}`
- `network.node node={} up={}`
- `network.link from={} to={} enabled={}`
- `network.partition left_count={} right_count={}`
- `network.heal disabled_count={}`

The payload is not dumped into the core network trace. User code should record
domain-specific payload facts separately when useful, as the replicated
register example does with `register.message`.

## Current Limits

`UnstableNetwork` does not yet support:

- Replay recording.
- Packet duplication.
- Path clogging.
- Broadcast.
- Node spawning.
- Event-by-event scheduler callbacks.

These are deliberate omissions. The current primitive should prove the
smallest useful packet core before growing.

## Next Step

The next high-value addition is path clogging. It would make the network model
closer to the failure shapes a real distributed system needs without
committing to the final node-scoped API yet.
