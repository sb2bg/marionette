# Determinism

Determinism is Marionette's core product. Given the same Marionette version,
Zig version, target platform, user code, simulation options, and seed, the
same simulation must produce the same declared result and byte-identical
Marionette trace. If it does not, the library has failed.

## The Rule

Simulated code must route non-deterministic behavior through Marionette
interfaces:

- Time through `Clock`.
- Randomness through seeded `Random` or `World`.
- Disk through the future Disk interface.
- Network through the future Network interface.
- Scheduling through the future scheduler.

Do not call host sources directly from simulated code.

## Banned Sources

These are banned in simulated code:

- `std.time.*`
- `std.Random` without an explicit seed.
- `std.crypto.random`
- `std.Thread.spawn`
- Filesystem calls outside the future Disk interface.
- Network calls outside the future Network interface.
- Pointer identity as a source of ordering or hashing.
- Hash map iteration order unless explicitly sorted or otherwise stabilized.

Phase 0 ships an AST-based `tidy` linter for the obvious direct-call cases.
It ignores comments and string literals, and it catches simple const aliases
such as `const time = std.time;`. It does not yet perform full semantic import
resolution.

## Enforcement Layers

Marionette enforces determinism in four layers.

1. API design.

   The intended path should be the easiest path. Users should have no reason
   to reach for `std.time.nanoTimestamp` when `World.clock()` is already in
   hand.

2. Build-integrated linter.

   The `marionette-tidy` executable parses Zig source with `std.zig.Ast`,
   scans for banned direct call paths, and can be wired into `zig build test`.
   Its defaults ban host time, host threads, host entropy, direct network
   access, and common direct filesystem entry points. Projects can add their
   own exact or prefix bans through `addTidyStep`.

   ```zig
   const marionette = @import("src/build_support.zig");

   const tidy = marionette.addTidyStep(b, .{
       .paths = &.{ "src", "examples", "tests" },
       .extra_patterns = &.{
           .{ .needle = "std.heap.page_allocator", .reason = "pass an allocator explicitly" },
       },
   });
   test_step.dependOn(&tidy.step);
   ```

3. Twice-and-compare runtime detector.

   `mar.run` runs a scenario twice with the same seed and compares
   byte-for-byte traces. A mismatch means non-determinism leaked.

4. Documentation.

   The rules and their reasons should be written down while the API is built,
   not reverse-engineered later.

## Single-Threaded Simulation

Simulated components are single-threaded. This is intentional.

Real threads introduce OS scheduling into the behavior under test. That makes
portable deterministic replay much harder and pushes the project toward a
different product category.

If production code needs parallelism, the Marionette-friendly options are:

- Run multiple `World` instances independently.
- Isolate parallel pieces behind deterministic interfaces.
- Test coordination logic in simulation and cover the remaining low-level
  concurrency with other tools.

If the main thing you need is adversarial scheduling of concurrent data
structures, you probably want a Shuttle-style tool rather than Marionette.

## No Syscall Interception

Marionette does not fake time with `LD_PRELOAD`, syscall interception, or
runtime patching.

The premise is that Zig code can be written against explicit interfaces. The
benefit is clarity and zero production overhead. The cost is discipline:
users must route effects through the interfaces Marionette can control.

## Trace Discipline

The trace is the observable record used by determinism tests.

Good trace events should be:

- Stable across platforms.
- Independent of pointer addresses.
- Independent of hash map iteration order.
- Specific enough to explain what the simulated service did.
- Small enough to compare cheaply.

Do not record wall-clock timestamps, memory addresses, thread ids, or
unordered container dumps.

The Phase 0 trace format is specified in [Trace Format](trace-format.md).
