# Trace Format

The trace is Marionette's replay artifact. Same seed means byte-identical
trace, so the bytes need a small spec.

## Text Format

Traces use newline-delimited UTF-8 text.

The first line is a header:

```text
marionette.trace format=text version=2
```

Version 1 (2026-06-11) added `io.random` events: every `Io.random` /
`Io.randomSecure` draw in simulation records its length and a fixed-seed
Wyhash digest of the produced bytes, so replay divergence is visible at the
draw site without inflating traces by buffer size.

Version 2 (2026-08-02) adds the mandatory `disk.model` event emitted when a
simulated disk is composed. This makes the portable disk semantic contract
and sector size explicit before any disk operation is traced.

Every later line is one event:

```text
event=<u64> <component>.<action> <key>=<value> ...
```

Example:

```text
marionette.trace format=text version=2
event=0 world.init seed=12648430 start_ns=0 tick_ns=1
event=1 run.name value=smoke
event=2 run.tag value=scenario:smoke
event=3 run.attribute key=packet_loss_percent value=uint:20
event=4 world.tick now_ns=1
event=5 world.random_u64 value=10121301305976376037
event=6 buggify hook=drop_packet rate=20/100 roll=73 fired=false
event=7 request.accepted id=42
```

Rules:

- Lines end with `\n`.
- Event indexes start at zero and increase by one for every `World.record`
  call and every traced simulator helper.
- Event indexes are global within one `World`.
- Component and action names use lowercase words separated by `_`, with one
  dot between the component and action. The current `buggify` event name is a
  short special case.
- Keys use lowercase words separated by `_`.
- Values must be non-empty stable text for the same Marionette version, Zig
  version, target platform, user code, options, and seed.
- `World.record` returns `error.InvalidTracePayload` if a formatted event
  payload is ambiguous: no leading, trailing, or repeated spaces; every field
  after the event name must be exactly `key=value`; keys may contain only
  lowercase ASCII, digits, and `_`; values may not contain space, `=`, newline,
  carriage return, tab, or `\`.
- `World.recordFields` writes the same event shape from structured fields.
  Text values are percent-encoded byte-by-byte for ambiguous bytes: space,
  `=`, `%`, `\`, ASCII control bytes, and non-ASCII bytes become `%HH`.
  Existing unambiguous ASCII such as `scenario:smoke` remains readable.
- Run attributes encode the Marionette scalar type in the value text:
  `string:<escaped-text>`, `int:<i64>`, `uint:<u64>`, `bool:<true|false>`, or
  `float:<f64>`.
- BUGGIFY events use
  `buggify hook=<comptime-tag> rate=<numerator>/<denominator> roll=<value> fired=<bool>`.
- Allocation authority events use `allocation.alloc`, `allocation.resize`,
  `allocation.remap`, and `allocation.free` with `op`, length, `align`,
  `status`, `reason`, `roll`, `live_bytes`, and `successful_allocations`
  fields. They never contain addresses.
- Cooperative cancellation records `scheduler.cancel_request task=<u64>` when
  a request is armed and `scheduler.cancel_deliver task=<u64>` when
  `error.Canceled` is delivered at a cancellation point.
- A proven scheduler deadlock records
  `scheduler.wait_state waits=<task>:<key>[@<deadline>],...` in task order,
  followed by `scheduler.deadlock tasks=<u64> completed=<u64> blocked=<u64>`.
- Watchdog-enabled runs record `run.watchdog` with the configured stall,
  total-run, and trace-capacity bounds. If the host worker must be terminated,
  the preserved trace ends with `watchdog.non_yielding task=<u64-or-main>` or
  `watchdog.livelock task=<u64>`. Host timestamps are never recorded. These
  optional and failure-only vocabulary additions do not change the text
  envelope, so the trace format remains version 2.
- Time-evolved simulator faults are preceded by
  `fault_evolution.boundary now_ns=<u64>`. Seeded scheduling draws and any
  network or process state transitions caused at that timestamp follow the
  boundary record.
- Unstable network events use `network.send`, `network.drop`, and
  `network.deliver` with stable packet ids and node ids.
- Node-state changes use `network.node`.
- Link-filter changes use `network.link`, `network.partition`, and
  `network.heal`. Link-only healing uses `network.heal_links`.
- Path-clog changes use `network.clog`, `network.unclog`, and
  `network.unclog_all`.
- The scheduler-backed stream adapter records `io.net.deliver` for delivered
  framed bytes and `io.net.delivery_error` when a delivery-time topology fault
  is translated into a stream error.
- Logical process lifecycle records use `process.kill node=<u64> reason=<literal>`
  and `process.restart node=<u64>`.
- Simulated disks begin with
  `disk.model contract=portable_v1 version=1 sector_size=<u64> torn_write=sector_prefix reorder=crash_global_reverse lifecycle=commit_pending`.
  A disk crash publishes all fault choices, per-write and per-metadata
  classifications, its summary, and process-kill records transactionally. If
  any trace allocation fails, none of that crash sequence remains visible.
- The one-shot liveness transition records `liveness.transition core_count=<u64>`
  followed by the zeroed-rate events and, when a network is configured,
  `network.liveness_restore` with `core_count`, `restored_links`,
  `cleared_clogs`, and `revived_nodes` fields.

## What Goes In

Record data that explains simulator decisions and user-visible simulated
behavior:

- Seed and simulation options.
- Time movement.
- Random choices that affect behavior.
- Scheduler decisions.
- Disk and network fault decisions.
- User service events that help explain a failure.
- Invariant failures and liveness failures.

## What Stays Out

Do not record:

- Pointer addresses.
- Stack or heap addresses.
- OS thread ids.
- Wall-clock timestamps.
- Hash map iteration order unless sorted first.
- Raw unordered container dumps.
- Host file descriptors.
- Platform-specific error strings when a stable code is available.

## Stability Policy

Trace bytes are guaranteed only within the full determinism contract: same
Marionette version, Zig version, target platform, user code, simulation
options, and seed.

If Marionette changes the trace layout, it must bump the trace format version.
If Zig's formatter changes output for a value, that is outside the cross-version
trace guarantee, but Marionette should avoid relying on ambiguous formatting in
core simulator events.
