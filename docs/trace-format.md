# Trace Format

The trace is Marionette's replay artifact. Same seed means byte-identical
trace, so the bytes need a small spec.

## Phase 0 Format

Phase 0 uses newline-delimited UTF-8 text.

The first line is a header:

```text
marionette.trace format=text version=0
```

Every later line is one event:

```text
event=<u64> <component>.<action> <key>=<value> ...
```

Example:

```text
marionette.trace format=text version=0
event=0 world.init seed=12648430 start_ns=0 tick_ns=1000000
event=1 run.profile name=smoke
event=2 run.tag value=scenario:smoke
event=3 run.attribute key=packet_loss_percent value=uint:20
event=4 world.tick now_ns=1000000
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
- Unstable network events use `network.send`, `network.drop`, and
  `network.deliver` with stable packet ids and node ids.
- Node-state changes use `network.node`.
- Link-filter changes use `network.link`, `network.partition`, and
  `network.heal`. Link-only healing uses `network.heal_links`.
- Path-clog changes use `network.clog`, `network.unclog`, and
  `network.unclog_all`.

## What Goes In

Record data that explains simulator decisions and user-visible simulated
behavior:

- Seed and simulation options.
- Time movement.
- Random choices that affect behavior.
- Future scheduler decisions.
- Future disk and network faults.
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

## Future Binary Format

A binary trace may be added later for speed, compactness, and tooling. If that
happens, text traces should remain available for debugging and examples.
