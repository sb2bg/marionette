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
var report = try retry_queue.runBuggyScenarioReport(allocator, 0xC0FFEE);
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

This example does not require disk or cooperative tasks. It shows the smaller
simulation loop directly: seeded choices, simulated time, trace-visible
behavior, and a named checker that preserves the failure context.

## KV Store

Source: [`examples/kv_store.zig`](https://github.com/sb2bg/marionette/blob/main/examples/kv_store.zig)

The KV store is the first disk-backed example. It is intentionally tiny: a
fixed-size append-only WAL where each sector is one record with a magic value,
key, value, and checksum. The store itself is production-shaped: it accepts
`std.Io`, a root `std.Io.Dir`, and a narrow `mar.Recorder`, then uses
`std.Io.File` positional read/write and `sync`. The harness still owns
Marionette's `Control` authority for disk faults, crash, restart, and scripted
corruption.

The correct scenario:

- Writes and syncs one committed record.
- Writes a second unsynced record.
- Crashes the disk so the unsynced record is lost.
- Restarts the disk.
- Injects scripted corruption into the second sector.
- Recovers by scanning records and validating checksums.
- Checks that the synced record is recovered exactly once and the unsynced
  record is rejected.

Run it with:

```sh
zig build run-example -- kv-store --seed 12648430 --summary
```

The deliberately buggy scenario accepts any record with the right magic value,
ignoring the checksum. A torn write leaves enough bytes for the magic and key
to look plausible, and the named checker catches that the unsynced record was
recovered:

```sh
zig build run-example -- kv-store-bug --seed 12648430 --expect-failure
```

Useful trace events include:

```text
disk.crash_write op=4 path=kv.wal offset=16 len=16 result=torn
kv.recover.record offset=16 key=2 value=0 mode=buggy_accept_magic_only
kv.invariant_violation reason=unsynced_record_recovered
```

## Idempotency Bug

Source: [`examples/idempotency_bug.zig`](https://github.com/sb2bg/marionette/blob/main/examples/idempotency_bug.zig)

The idempotency bug is a small seed-sensitive replay demo. It models two
account-local deposits. The service has a subtle bug: it dedupes request IDs
globally, even though request IDs are only required to be unique per account.

Most seeds choose distinct request IDs and pass. Seeds that reuse the same
request ID across two accounts suppress the second deposit, and the checker
catches the lost update.

Run a passing seed:

```sh
zig build run-example -- idempotency-bug --seed 12648430 --summary
```

Replay a failing seed:

```sh
zig build run-example -- idempotency-bug --seed 13 --expect-failure
```

Use `--trace` with the failing seed to print the same failure trace each time.

Useful trace events include:

```text
buggify hook=reuse_request_id_across_accounts
idempotency.requests alice_id=... bob_id=... reused=true
idempotency.deposit account=bob ... accepted=false reason=global_duplicate
idempotency.invariant_violation
```

## Replicated Register

Source: [`examples/replicated_register.zig`](https://github.com/sb2bg/marionette/blob/main/examples/replicated_register.zig)

The replicated register is the first VOPR-inspired showcase. It is not a real
consensus protocol and does not copy TigerBeetle internals. It demonstrates the
portable shapes Marionette needs:

- A small cluster model with three replicas.
- Seeded message drops and delivery latency.
- `world.simulate(.{ .network = ... })` producing typed
  `mar.Endpoint(MessagePayload)` node endpoints backed by fixed-topology per-link
  queues ordered by `(deliver_at, packet_id)`.
- A partition scenario that drops queued packets through directed link filters.
- Runtime network fault configuration through focused `control.network`
  helpers such as `setLossiness(...)`, `setLatency(...)`, `setClogs(...)`,
  and `setPartitionDynamics(...)`.
- `runCase` / `expectPass` / `expectFuzz` / `expectFailure` for scenario runs.
- Trace events for sends, drops, deliveries, accepts, commits, and checks.
- A named `mar.StateCheck` that inspects structured harness state.
- Rejection of conflicting same-version proposals.
- A parity test that initializes the same `Replicas` type with simulated and
  production-shaped network handles.

The normal scenario writes one value to a quorum, commits it, and checks that
committed replicas agree and that committed values were accepted by a quorum:

```zig
const trace = try replicated_register.runScenario(allocator, 0xC0FFEE);
defer allocator.free(trace);
```

The trace starts with the run name and records network fault configuration as
explicit control events, so the seed is not the only context available when a
failure is replayed.

The example also includes a deliberately buggy scenario used by tests to prove
the checker path catches divergent committed state:

```zig
var report = try replicated_register.runBuggyScenarioReport(allocator, 0xC0FFEE);
defer report.deinit();
```

The partition scenario isolates one replica from the client and majority, then
heals the network and replays the same value so the previously isolated replica
commits too:

```zig
const trace = try replicated_register.runPartitionScenario(allocator, 0xC0FFEE);
defer allocator.free(trace);
```

There is also a same-version conflict scenario used by tests to prove the
register rejects conflicting values instead of overwriting accepted state.

This is intentionally tiny. Its job is to keep the endpoint network and
invariant APIs concrete and regression-tested.

## std.Io.net KV

SUT source:
[`examples/std_io_net_kv.zig`](https://github.com/sb2bg/marionette/blob/main/examples/std_io_net_kv.zig)

Harness source:
[`validation/std_io_net_kv.zig`](https://github.com/sb2bg/marionette/blob/main/validation/std_io_net_kv.zig)

This external-style validation keeps Marionette out of the application module.
The SUT uses only `std.Io.net` to implement a fixed-frame PUT/GET protocol. The
harness owns cooperative tasks, network latency, partition/heal control, the
trace, and an exact retry-idempotency oracle.

The correct server caches responses by request ID. The harness partitions the
link after the first PUT response is queued, observes `error.Timeout`, heals,
and retries the same request. The server returns the cached response and keeps
`revision == 1`.

The planted buggy server reapplies the retry. The value remains 41, but the
revision and application count become 2, so the checker catches the duplicate
mutation.

```sh
zig build validate-std-io-net-kv
zig build run-example -- std-io-net-kv --seed 12648430 --trace
zig build run-example -- std-io-net-kv-bug \
  --seed 12648430 --trace --expect-failure
```

See [Testing std.Io.net Code Deterministically](std-io-net-example.md) for the
trace and supported stream boundary.

## Toy DB

Source: [`examples/toy_sql_db.zig`](https://github.com/sb2bg/marionette/blob/main/examples/toy_sql_db.zig)

The toy database is a tiny protocol-adapter example. Its wire format is just a
one-byte tag plus an optional little-endian `i64`. Its purpose is not SQL
coverage; it shows how a user-owned protocol can declare codecs for
`mar.CodecTransport` so database code sees typed `Request` and `Response`
values instead of Marionette vtables, byte buffers, or message-pool handles.

The scenario drives a client and server over simulated byte endpoints, so the
same adapter shape can later sit on production byte endpoints.

## Durable Broadcast

Source: [`examples/durable_broadcast.zig`](https://github.com/sb2bg/marionette/blob/main/examples/durable_broadcast.zig)

Durable broadcast is the first example that combines disk and network in one
harness. It models a service that writes one operation to a local WAL, syncs it,
then broadcasts the operation to three replicas and waits for a quorum of
acknowledgements.

The example is deliberately narrow: one fixed-size WAL record, one operation,
and scripted crash/restart. The roadmap tracks follow-ups for extracting the
duplicated WAL framing helper, adding a probabilistic buggy fuzz/search variant,
splitting happy-path and crash-recovery scenarios, and growing this into a
multi-record recovery case.

The checker asserts the cross-subsystem invariant:

- if a quorum acknowledged an operation, that operation must be recoverable from
  local durable storage after crash/restart;
- if any replica accepted an operation, it must match the recovered durable
  operation.

Run the correct scenario:

```sh
zig build run-example -- durable-broadcast --seed 12648430 --summary
```

The deliberately buggy scenario broadcasts before syncing. The replicas can
acknowledge the operation, then a crash loses the pending WAL write. The checker
catches that the network-visible operation was not durable:

```sh
zig build run-example -- durable-broadcast-bug --seed 12648430 --expect-failure
```

Useful trace events include:

```text
durable.broadcast.quorum op=1 value=99 acks=3
disk.crash_write op=0 path=durable_broadcast.wal offset=0 len=24 result=lost
durable.invariant_violation reason=quorum_without_durable
```

## Memtable Pressure

Source: [`examples/memtable_pressure.zig`](https://github.com/sb2bg/marionette/blob/main/examples/memtable_pressure.zig)

The memtable makes allocation failure a real modeled branch. Every `put`
copies its value through `env.allocator()`, so a deterministic OOM injected
via `control.allocation` must be rejected without mutating table state:

- Put key 1, then set `fail_after = 0` so every later allocation fails.
- Put key 2, which is rejected cleanly.
- Heal the faults and put key 3.

The checker asserts the committed count matches the stored entries exactly.
The planted bug counts an insert as committed before its allocations succeed,
so the injected OOM leaves a phantom commit:

```text
memtable.put key=1 accepted=true committed=1
allocation.alloc op=4 len=7 align=1 status=fail reason=fail_after roll=none ...
memtable.put key=2 accepted=false reason=allocation_rejected committed=2
memtable.invariant_violation reason=phantom_commit committed=3 entries=2
```

A third scenario fuzzes `buggify_rate` allocation faults across seeds and
asserts the table never records a commit it did not store.

## Example Rules

- Keep examples focused and readable.
- Prefer one clear service behavior over a broad feature tour.
- Route time and randomness through Marionette interfaces.
- Return or expose traces so tests can compare replay behavior.
- Avoid `std.time`, unseeded randomness, threads, filesystem, and network
  calls in simulated example code.
