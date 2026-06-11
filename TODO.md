# Project review findings (2026-06-10)

Findings from a full project review. Ordered roughly by severity within each
section. Check items off as they are fixed; link commits or issues inline.

## Bugs and correctness

- [x] **1. `Io.sleep` in simulation is broken in three ways**
      (`src/io/backend.zig` `simSleep`, `src/clock.zig` `runFor`)
  - [x] Crashes on non-tick-multiple durations: fixed via
        `SimClock.ceilDuration`; deadlines round up to tick resolution in
        `blockCurrentUntil` and in the bare-backend sleep path.
  - [x] Advances the global clock instead of parking the task: fixed; with a
        wait set attached, sleep parks on a `.sleep` wait key and
        `advanceToNextTimer` wakes earlier deadlines first
        (`error.InvalidDeadline` removed).
  - [x] Bypasses `World.runFor`: fixed; the bare-backend path now records
        `world.run_for`, and parked sleeps are traced through
        `scheduler.block`/`scheduler.timeout`.
  - [x] Follow-up fixed: `simSleep` now re-parks in a loop until
        `now >= deadline`, so a stray wake on the shared `(.sleep, 0)` key
        can no longer end a sleep early.
- [ ] **2. `SimClock.runFor` is O(duration / tick_ns)** (`src/clock.zig`)
  - [x] The tick-by-tick loop in `SimClock.runFor` itself was
        side-effect-free; collapsed to a single `advanceBy` jump.
  - [ ] `SimControl.runFor` (`src/env.zig`) and
        `TypedRuntime.runForDeterministicFaults` (`src/network/sim.zig`) are
        observably per-tick (each tick draws RNG for fault evolution and
        records `world.tick`), so collapsing them changes behavior. They
        need an event-driven redesign (jump to next deadline/clog expiry,
        evolve faults at event boundaries).
  - Agreed design (2026-06-10): land it now rather than defer; pre-1.0 is
    the cheapest time to break traces. Draw fault-event times from the seed
    directly (geometric next-occurrence instead of per-tick Bernoulli
    rolls) and bump `marionette.trace` to version 1. Session-sized
    refactor; read `docs/trace-format.md` first.
- [x] **3. File-layer length diverges from disk truth under crash faults**
      (`src/io/backend.zig`, `src/io/file.zig`, `src/disk/sim.zig`)
  - Fixed with crash-as-process-restart semantics: `SimDisk` notifies a
    crash observer; the `std.Io` backend closes every open file handle and
    marks cached metadata stale. Surviving files have their length
    re-derived from disk truth (`disk.stat`) on first touch after restart,
    while timestamps are preserved (filesystem timestamps survive a real
    machine crash). Tombstoned (deleted) metadata also goes stale at
    crash, so an unsynced deletion rolled back by `crash_lost_metadata`
    revives the tombstone with its pre-crash timestamps instead of
    rediscovering a fresh entry with mtime zero. The kv_store example and
    xitdb harness gained `reopen` steps modeling real recovery.
  - Known remaining edge: a crash-rolled-back *rename* can leave the live
    meta (renamed path) refreshing against the replaced file's content,
    carrying the renamed file's mtime onto it. Real fix is moving
    timestamp ownership into SimDisk (per-write timestamps at landing),
    part of the disk-model roadmap.
- [ ] **4. Futex key table grows unboundedly** (`src/io/backend.zig`
      `futexKey`)
  - Entries are never removed, so long-lived sims with many short-lived
    futexes leak table entries and slow the linear lookup.
  - Address reuse after free maps a new futex to the old key. For valid
    programs (no waiters left when the old futex dies) this is consistent
    and not a correctness bug, and logical keys keep raw addresses out of
    traces. Document this reasoning where the pointer-identity rule is
    knowingly bent, and add a growth bound or retirement scheme.
- [ ] **5. Network node IDs are consumed per socket and never recycled**
      (`src/io/backend.zig` `allocateNetworkNode`)
  - Reconnect loops exhaust the fixed topology and get `error.NetworkDown`.
    Closed handle state is also only freed at backend deinit.
  - Agreed design (2026-06-10): node = process. Each simulated process gets
    its own `Backend`/`std.Io` with a stable node identity; sockets become
    per-connection objects under that node, so connect/close cycles never
    consume topology. Requires a shared (world-level) listener/connection
    registry so connects rendezvous across backends, and futex key
    namespacing so per-backend keys cannot collide in the shared wait set.
    Session-sized refactor; rippling through scheduler net tests and
    validation harnesses.
- [x] **6. Fiber stacks have no overflow protection** (`src/fiber.zig`)
  - [x] Best-effort canary word at the stack's low end, checked by the
        scheduler after every context switch (panics on corruption).
  - [x] Guard pages on POSIX targets: fiber stacks come from mmap with an
        inaccessible page (MAP_FIXED PROT_NONE remap) below the usable
        region; heap + canary fallback elsewhere, with the munmap arm
        comptime-guarded (verified via x86_64-windows-gnu cross-compile).
        Landed together with the context-switch fix below, which the
        Fiber struct resize had originally exposed.

- [x] **P0: latent ReleaseSafe miscompilation around fiber context
      switches** ROOT-CAUSED AND FIXED LOCALLY (2026-06-10);
      upstream filing still to do (see below).
  - Root cause 1 (proven with a minimal standalone reproducer):
    `std.Io.fiber.contextSwitch` declares the message register (aarch64
    `x1`, x86_64 `rsi`, riscv64 `a1`) as input, output, AND clobber.
    Declaring an in/out register as a clobber is ill-formed asm; LLVM
    silently drops the copy of the input into that register under
    register pressure, and the switch dereferences caller garbage.
    Whether it bites depends on whether callers happen to compute the
    message into that register naturally, which is why HEAD passed by
    codegen luck and any perturbation (struct resize, noinline) broke it.
    Minimal reproducer (fails with `error.InputCopyDropped` at
    -OReleaseSafe; disasm shows no `mov x1, x0` emitted):

    ```zig
    noinline fn passThrough(p: *const u64) *const u64 {
        return asm volatile (""
            : [out] "={x1}" (-> *const u64),
            : [in] "{x1}" (p),
            : .{ .x0 = true, .x1 = true, .x2 = true, .memory = true });
    }
    pub fn main() !void {
        var value: u64 = 42;
        if (passThrough(&value) != &value) return error.InputCopyDropped;
    }
    ```

  - Root cause 2 (observed via instruction-level step trace of the
    residual hang): with the switch asm inlined into `runUntilIdle`,
    LLVM folded the loop's exit condition into a load from an anonymous
    rodata constant (layout matching an error-union `{err=0, true}`),
    wiring the "advanceToNextTimer returned false → break" path back
    into the loop head. The asm's local resume label is setjmp-like
    returns-twice control flow that the optimizer does not model.
  - Local fix in `src/fiber.zig` (`correctedContextSwitch`), both parts
    load-bearing: (a) std's asm for all three arches with the message
    register removed from the clobber list (plus `nzcv` added on
    aarch64, matching the rflags clobber std's own x86_64 variant has);
    (b) `noinline`, so the returns-twice label lives in a dedicated
    function and caller control flow sees a plain call. Verified: both
    previously deterministic reproducers pass, plus full Debug,
    ReleaseSafe, ReleaseFast (root module), all validations, and
    Windows/Linux cross-compiles.
  - [ ] File upstream against Zig `std.Io.fiber`: the in/out-register-
        in-clobbers bug (with the minimal reproducer above, affects all
        three arch variants), the missing aarch64 `nzcv` clobber, and
        the returns-twice inlining hazard. Remove the local copy once
        fixed upstream.
  - Diagnosis credit: structural comparison against zio
    (`.references/zio/src/coro/coroutines.zig`) narrowed the search;
    its switch keeps flags clobbered and passes data through memory.

## Tidy linter gaps

- [x] Stale allowlist entry: `src/clock.zig` allowance for `std.time`
      removed; the blanket-allow test now uses an explicit fixture
      (`src/tidy.zig` `default_allowed`).
- [x] Missing default bans: added `std.posix`, `std.process`,
      `std.heap.page_allocator`, and `std.Options.debug_io` to the default
      patterns, with narrow `Allow` entries for CLI entry points (process)
      and scheduler/validation test harnesses (page_allocator).
- [x] Marionette's own `ProductionClock` used `std.Options.debug_io`; it
      now takes the host `std.Io` at construction, injected by
      `Production.init` (`src/clock.zig`, `src/env.zig`).

## Style and consistency

- [x] `env.Random` doc comments said "untraced from host entropy"; now
      describe both the traced simulation path and the untraced production
      path (`src/env.zig`).
- [ ] `Production.Options.allocator` defaults to `std.heap.smp_allocator`
      (`src/env.zig`); consider making it required per the allocator
      discipline principle. The noop tracer's `smp_allocator` return is dead
      code but a footgun.
- [ ] Inconsistent misuse contracts: `SimControl.runFor` returns
      `error.InvalidDuration` while `World.runFor`/`SimClock.runFor` assert.
- [ ] Inconsistent random consumption for disabled hooks: disk `rollFault`
      skips the draw when `numerator == 0`, `Env.buggify` always draws.
      Pick one convention.
- [ ] Files exceed the 500-line guideline (`scheduler.zig` 1667,
      `disk/sim.zig` 1294, `run.zig` 1081); move scenario-style tests into
      sibling test files.
- [x] Unbounded spin loop in `validation/std_io_net_kv.zig` `serverTask`
      now panics after 32 yields like its siblings.
- [x] Harness-wide polling cleanup: "wait until peer is parked" cannot be
      converted to wake-key handshakes (a task cannot signal after it
      suspends), so the poll is inherent. Added
      `TaskScheduler.yieldUntilBlockedCount` (bound 256, documented) and
      converted the blocked-count poll sites to it; remaining flag polls
      raised from 32 to 256 yields with u16 counters. Starvation odds at
      256 yields are negligible for any seed sweep.
- [x] `expectFuzz` seed derivation: the old `base ^ const ^ iteration`
      made bases differing only in their low `log2(seed_count)` bits cover
      identical seed sets. Fixed with the keyed two-dimensional derivation
      `splitmix64(base ^ splitmix64(iteration))`, with a regression test
      (`src/run.zig` `fuzzSeed`).

## Missing infrastructure

- [ ] CI job verifying sim-mode symbols are absent from release binaries
      (promised by CLAUDE.md principle 2; currently unverified).
- [ ] Multi-platform CI (macOS, Windows); only ubuntu runs today.
- [ ] Nightly long-running seed-sweep job (`expectFuzz` over examples with
      thousands of seeds).
- [ ] CLAUDE.md directory layout is stale: lists `examples/rate_limiter.zig`
      and `tests/tidy_self_check.zig` (neither exists), omits `src/io/`,
      `src/network/`, `src/disk/`, `validation/`, `docs/`.

## std.Io scheduling milestone (2026-06-11)

- [x] Traced `Io.random`/`Io.randomSecure`: `io.random len=N digest=H`
      events (fixed-seed Wyhash digest of the bytes). Trace header bumped
      to `version=1`; documented in `docs/trace-format.md`.
- [x] Scheduling inside `std.Io`: `World.simulate` now owns a cooperative
      scheduler (teardown-registered) and attaches both the futex wait set
      and a new type-erased `TaskRuntime` seam (`src/io/task.zig`) to the
      backend. `Io.async`/`Io.concurrent` spawn deterministic tasks with
      seeded, replay-visible interleaving; `await` parks in-task or drives
      the scheduler from the scenario context (`runUntilDone`); `cancel`
      awaits completion (cooperative tasks cannot be preempted). Bare
      backends keep the old semantics (eager async,
      `error.ConcurrencyUnavailable` for concurrent). `runUntilIdle` was
      refactored into a shared `stepOnce` (verified under ReleaseSafe).
- [ ] `Io.Group` (`groupAsync`/`groupConcurrent`/`groupAwait`/`groupCancel`)
      still fails closed, matching the current state of Zig's own
      fiber-backed backends. Implement once the single-future path has
      mileage.
- [ ] Cooperative cancellation points: `cancel` currently awaits; a real
      implementation needs cancel-request state surfaced through
      `checkCancel` at suspension points.
- [x] Fiber stacks are now unwind-safe (was: testing.allocator crashed on
      fiber-side alloc/free). Root cause per review: the entry stack had no
      valid termination, with an uninitialized return-address slot on
      x86_64 and a stale link register on aarch64/riscv64, so DWARF
      unwinders restored garbage caller state. Fixed with a zeroed sentinel
      root frame below the start closure plus link-register zeroing in the
      entry trampoline (zio's scheme). Pinned by a regression test that
      allocs/frees through `std.testing.allocator` inside a task, and the
      io async tests run on `std.testing.allocator` again (leak checking
      restored).
- [ ] Windows x86_64 fiber entry uses the SysV argument register (`rdi`);
      the Win64 ABI passes the first argument in `rcx`. Pre-existing,
      compile-only verified today; fix alongside the first real Windows CI
      run (zio's coroEntry has the win64 variant to crib from).
- [x] Review fix (P1): main-context blocking no longer panics. Wait-set
      calls with no current task route to `driveMainUntil`: the main
      context drives the scheduler (ready tasks run, time advances to the
      nearest task/caller deadline, due tasks wake at their own deadlines)
      until a `wake` hits its key or its deadline passes. The main waiter
      is woken before task waiters (fixed, deterministic priority; traced
      as `scheduler.wake_main`). A main wait with no runnable work, no
      timers, and no deadline panics as a deterministic deadlock. Note the
      semantic change: main-context empty accept with nothing pending now
      deadlock-panics instead of returning `WouldBlock` (the bare-backend
      `WouldBlock` path is unchanged).
- [x] Review fix (P1): completed tasks release their fibers eagerly. The
      `stepOnce` completion arm destroys the fiber (256 KiB stack) as soon
      as the task can never run again; `OpaqueEntry` adapters free
      themselves at task start. Remaining growth per completed task is one
      small `Task` record in `tasks` (kept for `completedCount` and id
      lookup); recycle those if worlds ever run task counts where a linear
      scan or the records themselves matter.
- [ ] Validation harnesses still construct their own
      `mar.experimental.TaskScheduler` and re-attach its wait set, leaving
      the world-owned scheduler idle (last-attach-wins, so behavior is
      consistent). Migrate them to `io.async` and retire the experimental
      exports once net-wait ergonomics (peer-parked handshakes) no longer
      need direct scheduler access.
