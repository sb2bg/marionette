# Examples

Examples are small enough to read quickly, but they exercise the real
Marionette APIs. Each example should become useful input for deterministic
replay tests. The example set is intentionally small while the API is
experimental.

The examples module root is [`examples/root.zig`](https://github.com/sb2bg/marionette/blob/main/examples/root.zig).
Add new examples there so `zig build test` picks them up without hard-coding
each example in `build.zig`.

## Retry Queue

Source: [`examples/retry_queue.zig`](https://github.com/sb2bg/marionette/blob/main/examples/retry_queue.zig)

The retry queue is the README-facing bug demo. It models a single leased job:

- Worker 1 leases the job.
- The lease times out.
- Worker 2 leases the same job.
- A late completion from worker 1 arrives after worker 2 owns the lease.

The correct scenario rejects the stale completion and then accepts worker 2's
completion. The deliberately buggy scenario accepts both completions, and a
named `mar.StateCheck` catches the duplicate completion:

```zig
var report = try retry_queue.runBuggyScenario(allocator, 0xC0FFEE);
defer report.deinit();
```

The useful trace shape is:

```text
queue.lease job=7 worker=1 deadline_ns=5000000
queue.timeout job=7 worker=1
queue.lease job=7 worker=2
queue.complete job=7 worker=1 accepted=true reason=stale_ack_bug completions=1
queue.complete job=7 worker=2 accepted=true reason=current_lease completions=2
queue.invariant_violation job=7 completions=2
```

This example does not require disk or a real scheduler. It shows the smaller
Phase 0 loop Marionette is proving first: seeded choices, simulated time,
trace-visible behavior, and a named checker that preserves the failure
context.

## Replicated Register

Source: [`examples/replicated_register.zig`](https://github.com/sb2bg/marionette/blob/main/examples/replicated_register.zig)

The replicated register is the first VOPR-inspired showcase. It is not a real
consensus protocol and does not copy TigerBeetle internals. It demonstrates the
portable shapes Marionette needs:

- A small cluster model with three replicas.
- Seeded message drops and delivery latency.
- `mar.UnstableNetworkSimulation` routing packets through a fixed topology and
  per-link queues ordered by `(deliver_at, packet_id)`.
- A partition scenario that drops queued packets through directed link filters.
- `RunOptions.profile_name`, tags, and `RunAttribute` for replay-visible
  knobs.
- Trace events for sends, drops, deliveries, accepts, commits, and checks.
- A named `mar.StateCheck` that inspects structured cluster state.
- Rejection of conflicting same-version proposals.

The normal scenario writes one value to a quorum, commits it, and checks that
committed replicas agree and that committed values were accepted by a quorum:

```zig
const trace = try replicated_register.runScenario(allocator, 0xC0FFEE);
defer allocator.free(trace);
```

The trace starts with the profile and expanded knobs, including replica count,
quorum, queue capacity, proposal drop percent, and retry limit. Those
attributes are derived from typed run profile structs with
`mar.runAttributesFrom` so the trace-visible facts stay tied to the config the
scenario executes. Field names are intentionally exported as attribute keys.
That keeps the showcase aligned with the VOPR lesson that a seed alone is not
enough context for a failure.

The example also includes a deliberately buggy scenario used by tests to prove
the checker path catches divergent committed state:

```zig
var report = try replicated_register.runBuggyScenario(allocator, 0xC0FFEE);
defer report.deinit();
```

The partition scenario derives its groups from the run profile, isolates one
replica from the client and majority, then heals the network and replays the
same value so the previously isolated replica commits too:

```zig
const trace = try replicated_register.runPartitionScenario(allocator, 0xC0FFEE);
defer allocator.free(trace);
```

There is also a same-version conflict scenario used by tests to prove the
register rejects conflicting values instead of overwriting accepted state.

This is intentionally tiny. Its job is to make the future scheduler, network,
and invariant APIs concrete enough to critique before they become core library
surface.

## Example Rules

- Keep examples focused and readable.
- Prefer one clear service behavior over a broad feature tour.
- Route time and randomness through Marionette interfaces.
- Return or expose traces so tests can compare replay behavior.
- Avoid `std.time`, unseeded randomness, threads, filesystem, and network
  calls in simulated example code.
