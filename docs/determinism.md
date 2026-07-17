# Determinism

Determinism is Marionette's core product. Given the same Marionette version,
Zig version, target platform, user code, simulation options, and seed, the
same simulation must produce the same declared result and byte-identical
Marionette trace. If it does not, the library has failed.

## The Rule

Simulated code must route non-deterministic behavior through Marionette
interfaces:

- Application clocks, sleeps, random bytes, tasks, file operations, and socket
  operations through `Env.io()`; harness time through `Control` or the
  explicitly low-level `World.clock()`.
- Application random algorithms through `std.Random.IoSource` over `Env.io()`;
  simulator-internal choices through the seeded `World` helpers.
- Allocation through `Env.allocator()` or another caller-provided allocator.
- Disk through Marionette's `Disk` capability.
- Network through Marionette `Endpoint` handles or node-scoped simulated
  `std.Io.net` obtained from `sim.envForNode(node).io()`.
- Cooperative scheduling through Marionette's task scheduler.

Do not call host sources directly from simulated code.

## Banned Sources

These are banned in simulated code unless they live in a narrowly allowlisted
composition root or diagnostic harness:

- Constructing an independent host backend such as `std.Io.Threaded`,
  `std.Io.Evented`, `std.Io.Dispatch`, `std.Io.Kqueue`, or `std.Io.Uring`.
- Host thread APIs such as `std.Thread.*`
- Raw host access through `std.os`, `std.posix`, C FFI, inline assembly, or
  equivalent application imports.
- Host process and machine queries that do not take an `std.Io`, such as user
  lookup, base address, and total system memory.
- Global debug/log sinks, ambient allocator singletons, and independently
  seeded PRNGs whose seed came from host state.
- Pointer identity as a source of ordering or hashing.
- Hash map iteration order unless explicitly sorted or otherwise stabilized.

Marionette ships an AST-based `tidy` linter for the obvious direct-call cases.
It ignores comments and string literals, and it catches simple const aliases
such as `const os = std.os;`. It does not yet perform full semantic import
resolution, inspect arbitrary C imports, or prove which `std.Io` value a caller
passes.

## What `Env.io()` Covers

Zig 0.16 moved both clocks and entropy behind `std.Io`, so Marionette does not
need parallel clock and random interfaces. The simulation backend currently
covers:

- `.real`, `.awake`, and `.boot` clock reads, clock resolution, sleeps,
  deadlines, and timer wakeups. Unsupported CPU-process and CPU-thread clocks
  have deterministic fail-closed behavior: zero timestamps, unavailable
  resolution, and no-op sleeps.
- `std.Io.random`, `std.Io.randomSecure`, and therefore
  `std.Random.IoSource`. Draws use the world's seeded stream and record
  `io.random` events.
- Async/concurrent tasks, groups, cancellation, futex waits/wakes, and queued
  operations through the deterministic scheduler.
- The modeled file/directory subset implemented over `SimDisk` and the modeled
  IP listen/connect/accept/read/write/close, shutdown, and DNS subset.

The same application calls use host behavior when `Production` supplies a host
`std.Io`. This is capability substitution: `std.Io` is not a promise that
Marionette implements every operation. Unsupported simulation operations fail
closed. Current gaps include atomic file creation, directory deletion,
links/realpaths/ownership/permissions, file mmap and standard file locks;
process spawn/replace/current-directory/executable operations; Unix sockets,
socket pairs, raw bind/send and zero-copy network writes, interface-name
queries; CPU clocks; and TTY/progress facilities.

## What `Env.io()` Cannot Cover Alone

`std.Io` controls effects performed through its vtable. It cannot make inputs
or effects deterministic when code obtains them elsewhere:

- Process arguments, environment variables, preopened directories, user
  configuration, and inherited handles are inputs assembled by the composition
  root. They must be captured or injected explicitly. Zig's `Dir.cwd()` and
  standard-file values are inert handles whose operations are still mediated
  by the supplied `std.Io`; an already-opened foreign handle is nevertheless
  external input.
- Allocation is a separate interface. Passing an allocator is sufficient for
  ordinary code, while `Env.allocator()` adds deterministic simulated OOMs;
  pointer values must still never enter behavior or traces.
- A caller can retain another host `std.Io`, construct its own PRNG, call raw
  OS/C APIs, use threads, consult process/machine state, or communicate through
  an external library that bypasses `std.Io`. Tidy catches common syntax, not
  all semantic aliases or foreign calls.
- Global debug logging, or standard streams used with a global/foreign I/O
  backend, bypass the environment's trace contract.
- Target, Zig/Marionette version, build options, undefined behavior, and
  algorithmic sources such as pointer-based ordering remain outside the I/O
  boundary and are part of the replay contract or must be eliminated.

The practical rule is therefore stronger than “take an `std.Io`”: simulated
application code receives only `env.io()` and explicit data/handles, and does
not retain or construct another authority. Marionette is an interface boundary,
not syscall interception or a security sandbox.

## Enforcement Layers

Marionette enforces determinism in four layers.

1. API design.

   The intended path should be the easiest path. Users should have no reason
   to reach for a host backend when `Env.io()`, `Control`, or `World.clock()`
   is already in hand.

2. Build-integrated linter.

   The `marionette-tidy` executable parses Zig source with `std.zig.Ast`,
   scans for banned direct call paths, and can be wired into `zig build test`.
   Its defaults ban independent host I/O backends, raw OS access, host threads,
   ambient allocators, global debug/log sinks, and host-only process queries.
   Projects can add their own exact or prefix bans through `addTidyStep`.

   ```zig
   const marionette_build = @import("marionette");

   const tidy = marionette_build.addTidyStep(b, .{
       .paths = &.{ "src", "examples", "tests" },
       .extra_patterns = &.{
           .{ .needle = "std.heap.page_allocator", .reason = "pass an allocator explicitly" },
       },
   });
   test_step.dependOn(&tidy.step);
   ```

   The imported build API locates its own dependency and gives the executable a
   dependency-owned path to Marionette's tidy entry point. Scan paths remain
   relative to the consuming project.

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

## Randomness and Misuse Conventions

Two conventions keep seed streams and harness contracts uniform across the
simulator:

- **Disabled faults consume no randomness and emit no trace.** A fault hook
  with a zero rate (`.never()`, `numerator == 0`) returns without drawing
  from the world's random stream and without recording a trace event. The
  disk model's `rollFault` and `Env.buggify` both follow this rule. Toggling
  a fault off therefore never shifts unrelated draws through call sites
  that would have rolled zero; enabling a fault does shift downstream
  draws, which is inherent to injecting it. A convention change here shifts
  seed streams, so any future revision must land inside a release boundary.
- **Misaligned `runFor` durations are harness misuse and assert.** `World`,
  `SimClock`, `SimControl`, and the network control all assert that a
  `runFor` duration is a whole number of ticks instead of returning
  `error.InvalidDuration`. Errors are reserved for conditions a correct
  harness can encounter at runtime; a misaligned duration is a bug in the
  test.
