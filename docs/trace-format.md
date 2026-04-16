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
event=1 world.tick now_ns=1000000
event=2 world.random_u64 value=10121301305976376037
event=3 request.accepted id=42
```

Rules:

- Lines end with `\n`.
- Event indexes start at zero and increase by one for every `World.record`
  call and every traced simulator helper.
- Event indexes are global within one `World`.
- Component and action names use lowercase words separated by `_`, with one
  dot between the component and action.
- Keys use lowercase words separated by `_`.
- Values must be stable text for the same Marionette version, Zig version,
  target platform, user code, options, and seed.

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
