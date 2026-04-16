# CLAUDE.md

This file is read by Claude Code at the start of every session. It describes
the Marionette project, its long-term vision, and what we're working on right
now. Read it carefully before making any suggestions or writing any code.

---

## What Marionette is

Marionette is a **deterministic simulation testing (DST) library for Zig**.

The core promise: you write a service against Marionette's interfaces (Clock,
Random, Disk, Network). In production, those interfaces compile down to direct
syscalls with zero overhead. In tests, they route through a simulator that
gives you:

- **Perfect reproducibility** — one seed produces one exact execution, every
  time, forever.
- **Time control** — simulate hours of system behavior in seconds of wall
  time by fast-forwarding the simulated clock.
- **Fault injection** — drop packets, corrupt disk writes, partition the
  network, skew clocks, crash nodes — all controlled by the seed.
- **Time-travel debugging** — when a bug is found, replay the exact execution
  and scrub through simulated time to find the root cause.

The inspiration is FoundationDB's original simulation framework and
TigerBeetle's VOPR (Viewstamped Operation Replicator). The novelty is making
this pattern available as a general-purpose library that any Zig service can
adopt, rather than something you have to rebuild from scratch inside your
project.

## Why this matters

Distributed systems bugs are the worst bugs. They appear in production at
3am, refuse to reproduce locally, and cost real money. Traditional testing
finds them by accident, if at all. DST finds them systematically, and once
found, they're permanently reproducible.

The technique is well-proven (FoundationDB, TigerBeetle, Antithesis as a
company, Resonate, Turso's rewrite) but it's historically only available to
teams willing to rewrite their whole stack around it. Marionette changes that
for the Zig ecosystem.

## Why Zig specifically

Marionette is feasible in Zig in a way it isn't in other languages:

- **No hidden allocations.** Allocator-passing is cultural, so swapping in a
  deterministic allocator for tests is natural, not exotic.
- **No runtime.** No goroutine scheduler, no async runtime to fight. The
  scheduler is ours.
- **Comptime.** The sim/production switch vanishes in release builds via
  dead-code elimination. Same binary tested is the binary shipped.
- **Idiomatic interface-passing.** Well-written Zig services already take
  their dependencies as parameters. Marionette slots in.
- **io_uring-native ecosystem.** The abstractions Marionette needs (event
  loop, IO interface) already exist in Zig idiom.

Go cannot do this without forking the runtime (Polar Signals tried). Rust
can do it but painfully (tokio compatibility is a constant fight — see
MadSim, Turmoil, mad-turmoil). Zig can do it cleanly. That's the whole
point.

### NOTE:

Marionette targets Zig 0.16.0. It should align with the new `std.Io`
direction where possible, but Phase 0 has not implemented a public `std.Io`
adapter layer yet. Today the stable surface is `World`, `Clock`, and `Random`.
For disk and network work, keep the public effect surface narrow so future
`std.Io` churn is absorbed inside adapters instead of pushed onto users.

Read `docs/architecture.md` before changing simulator fundamentals. It records
the determinism contract, IO strategy, time model, randomness model, non-goals,
multi-node direction, thread-safety stance, and target `marionette.run`
walkthrough. Read `docs/trace-format.md` before changing trace bytes. Read
`docs/buggify.md` before implementing fault hooks.

---

## Foundational design decisions

These decisions shape everything else. They were made deliberately and
should not be relitigated without a recorded discussion.

### Philosophy: library, not platform

There are two philosophies for how a DST system can work:

1. **Library.** Users write code against our interfaces. We provide clean
   interfaces; users write deterministic code. TigerBeetle, FoundationDB.
2. **Platform.** Users write whatever they want. We intercept syscalls, fake
   clocks via `LD_PRELOAD`, patch transitive deps. Antithesis, MadSim.

**Marionette is a library.** The platform approach is heroic engineering
(constant whack-a-mole with non-determinism leaks), compromises on guarantees,
and fights the language's design. Zig's idioms — allocator-passing,
interface-passing, no hidden state — make the library approach natural. We
lean into that.

Practical consequence: when someone asks "can Marionette also intercept
X without my code changing?" the answer is "no — you make X go through
our interface, or you don't use Marionette for X." That's a feature, not a
limitation. It's what lets us have a crisp correctness story.

### No faketime, no LD_PRELOAD, no syscall interception

We do not use `libfaketime` or similar mechanisms to intercept `std.time`
calls. Reasoning:

- It defeats the architectural premise. "Use our interfaces" is our pitch;
  reaching for LD_PRELOAD admits it doesn't work.
- It doesn't compose with comptime. Faketime is a runtime mechanism — we
  lose the "same binary in test and prod" story.
- It's Linux/macOS only. Windows has different interception mechanisms. We
  target all platforms Zig targets.
- Partial coverage creates false confidence. Faketime covers `clock_gettime`
  but not hash map iteration order, allocator randomness, or thread
  scheduling. Users would trust the simulator more than they should.
- Debugging is worse. A stack frame showing `marionette.Clock.now()` is
  clearer than one showing `clock_gettime` returning 1970.

Instead: ban direct `std.time` calls outside `ProductionClock`. Enforce
through the layered mechanism described in "Enforcement" below.

### Single-threaded simulated components

Marionette's simulator runs all simulated components on a single OS thread.
This is non-negotiable for Phase 0 through Phase 2, and probably forever.

**Rationale.** Determinism and real threads are fundamentally incompatible
without OS-level tools like rr or Hermit, which are 10-year projects we're
not building. Attempting to "mostly" support threads would produce a
product that's unreliable in exactly the situations DST is meant to cover.

**What this means for users.** Your service's simulated components must run
on a single thread. If your production architecture needs parallelism:

- Run multiple `World` instances in separate OS threads. Each is
  deterministic on its own. Cross-world coordination is up to you.
- Isolate the parallel parts behind an interface Marionette can simulate
  sequentially. Test the coordination logic; trust the OS primitives.
- Accept that some subsystems are not Marionette-tested and cover them
  with traditional tools.

**What TigerBeetle does.** VOPR runs an entire replicated cluster on one
thread. Finds hundreds of bugs. The fact that TigerBeetle's production
runtime is also single-threaded (one core per replica) isn't a coincidence
— it's a design philosophy. DST works when you shape your system to be
testable.

**A future, separate product.** "Shuttle for Zig" — a testing library
specialized for concurrent data structures under adversarial scheduling —
is a valid project. It's not Marionette. If the threading question gets
loud in the community, that's the right second library to build.

### Determinism enforcement

Discipline without mechanism is wishful thinking. Marionette enforces
determinism in four layers:

**Layer 1 — API design.** The right path is the easy path. `World.clock()`
returns a clock users just pass around. They don't reach for `std.time`
because they don't need to.

**Layer 2 — Build-integrated linter.** Marionette ships a `tidy` executable
that parses Zig source and scans for banned direct call paths
(`std.time.nanoTimestamp`, `std.Thread.spawn`, `std.crypto.random`, etc.).
Users wire it into their `build.zig` as a dependency of their test step.
Build fails if violations are found. Phase 0 uses AST matching and catches
simple const aliases such as `const time = std.time;`. Phase 1 can add fuller
import resolution.

**Layer 3 — Twice-and-compare runtime detector.** The simulator runs every
test twice with the same seed and compares byte-for-byte traces. If output
differs, non-determinism leaked somewhere. This is the backstop that
catches what the linter misses. Every user gets this for free; it's not
optional. This is probably Marionette's single most valuable feature.

**Layer 4 — Documentation.** The determinism discipline guide explains
the rules, the reasoning, and the common gotchas.

Treat any non-determinism leak as a **P0 bug**. Marionette's credibility
dies the first time it claims determinism and doesn't deliver it.

---

## Long-term vision (12+ months)

Marionette becomes the default answer when a Zig developer asks "how do I
test this distributed service?" The strategic goals, in order:

1. **Correctness.** If Marionette ever claims determinism and doesn't deliver
   it, the project is dead. Every feature must preserve the core guarantee.
2. **Ergonomics.** Adoption has to be easier than the alternative of
   reimplementing DST from scratch. The happy path should be obvious.
3. **Zero production cost.** Sim-mode paths must be dead-code-eliminated in
   release builds. Users pay nothing for what they don't use in prod.
4. **Ecosystem.** Eventually, a "Marionette-compatible" badge for Zig
   libraries that commit to determinism, so users know which deps are safe.
5. **Leadership.** Talks, blog posts, case studies. The TigerBeetle team has
   done this well; follow their playbook of transparent, technical writing.

## Roadmap

### Phase 0: Proof of concept (current phase, weeks 1–4)

**Goal:** Prove deterministic replay works for a trivial example in Zig, and
establish the foundational interfaces and patterns. No external users. No
API stability.

**Deliverables:**

- `World` struct owning a seeded PRNG and a fake clock.
- `Clock` interface with production and simulated implementations.
- A trivial demo service that uses the Clock (rate limiter or similar).
- A versioned text trace format with global event indexes.
- A test that runs the demo 1000+ times with a fixed seed and asserts every
  run produces byte-identical output.
- A fuzz test that runs across many seeds and asserts no panics.
- **Layer 3 detector**: simulator auto-runs every scenario twice and
  compares traces. Non-negotiable even in Phase 0 — proves the concept.
- **Layer 2 linter**: basic AST-based `tidy` executable that scans for
  banned direct call paths. Phase 0 ships with a minimal banned list and
  simple const alias detection.
- A written architecture contract for determinism, time, randomness, IO
  strategy, and simulator scope.
- A documented zero-cost BUGGIFY shape verified with ReleaseFast disassembly.
- A README explaining the project honestly.

**Done means:**

- `zig build test` passes deterministically.
- The twice-and-compare detector catches a deliberately injected
  non-deterministic call in a demo.
- The linter catches a deliberately injected `std.time.nanoTimestamp` call
  in a demo.
- Another Zig developer can understand the architecture in under 30 minutes.

### Phase 1: Single-node MVP (months 2–3)

Stable `Clock`, `Random`, and `Disk` interfaces. Fault injection for disk.
Example services (KV store, job queue). Docs on allocator discipline and
the banned-std-calls discipline. Linter upgraded with fuller import
resolution on top of `std.zig.Ast`.

**Done means:** Someone can adopt Marionette for a single-node Zig service
and get reproducible tests with time and disk fault control.

### Phase 2: Multi-node (months 4–7)

`Network` interface with partition, delay, drop, reorder. Node spawning
(`World.spawnNode`). Single-threaded cooperative scheduler for simulated
nodes. A real example: a small Raft or VSR implementation tested end-to-end.

**Done means:** Marionette can test a multi-node distributed system in a
single process under arbitrary network faults.

### Phase 3: Production-grade (months 8–12)

Linearizability checker. Time-travel debugging (cursor API). Seed shrinking.
Trace export. Dependency audit tooling (catches banned calls in transitive
deps, which the Phase 1 linter does not). Public case studies.

### Phase 4: Ecosystem leadership (year 2)

Conference talks. Blog series. Potentially a hosted continuous fuzzing
service.

---

## Current phase: Phase 0

Everything else in this file is context for Phase 0 work.

### Phase 0 task list

Work these in order. Each task should result in a commit.

- [ ] **T0**: Project skeleton. `zig init`, set up `build.zig` and
      `build.zig.zon`. Pin Zig version in a `.zig-version` file. Pin to the
      latest stable release for Phase 0.
- [ ] **T1**: `src/random.zig` — `Random` interface. Thin wrapper over
      `std.Random` that in sim mode is seeded and reproducible. Tests that
      the same seed produces the same sequence across runs.
- [ ] **T2**: `src/clock.zig` — `Clock` interface with `now()` and
      `sleep()`. Two implementations: `ProductionClock` (calls
      `std.time.nanoTimestamp`) and `SimClock` (advances on tick). Comptime
      switch between them.
- [ ] **T3**: `src/world.zig` — `World` struct that owns a `SimClock` and
      a `Random`. Exposes `tick()` to advance one step, `runFor(duration)`,
      traced random helpers including unbiased `randomIntLessThan`, and a
      **trace log** that records every action taken with a version header and
      global event indexes. The trace is what the Layer 3 detector compares.
- [ ] **T4**: `examples/rate_limiter.zig` — a trivial service that uses
      `Clock` and traced `World` randomness. Scheduled events so the Clock
      matters. Under 100 lines.
- [ ] **T5**: `tests/determinism.zig` — run the rate limiter 1000 times
      with the same seed. Assert traces are byte-identical across all runs.
      This is the core test of the project.
- [ ] **T6**: `tests/fuzz.zig` — run the rate limiter across 1000
      different seeds. Assert no panics. Print the seed on failure so it
      can be replayed.
- [ ] **T7**: `src/tidy.zig` + `src/main_tidy.zig` + `src/build_support.zig`
      — the Layer 2 linter, integrated as a Zig build step. Three pieces:
      (a) `src/tidy.zig` — the scanning logic as a library module, parsing
      `.zig` files with `std.zig.Ast` and matching banned direct call paths.
      (b) `src/main_tidy.zig` —
      the CLI executable entry point `marionette-tidy` that wraps the
      library. (c) `src/build_support.zig` — exposes
      `marionette.addTidyStep(b, .{ .paths = &.{"src"} })` for users to wire
      into their `build.zig` as a dependency of their test step. Starts
      with a small banned list: `std.time.nanoTimestamp`,
      `std.time.milliTimestamp`, `std.Thread.spawn`, `std.crypto.random`.
      Allowed-in list for our own wrappers. Exit non-zero on violations.
      The one-liner for users is non-negotiable — adoption friction is the
      main failure mode of a linter nobody runs.
- [ ] **T8**: `src/world.zig` addition — the Layer 3 "twice and compare"
      detector. A `World.verifyDeterministic` helper that runs a scenario
      twice with the same seed and asserts traces match. Tests for this
      helper with deliberately-injected non-determinism.
- [ ] **T9**: `tests/tidy_self_check.zig` — verify the linter catches a
      deliberately-injected `std.time.nanoTimestamp` call. Proves the
      mechanism works end-to-end.
- [ ] **T10**: `README.md` — honest public-facing description.
- [ ] **T11**: CI via GitHub Actions. Run `zig build test` on every push.
      Fuzzer budget of 30 seconds. Tidy runs on every build.

After T11: stop and evaluate against the signal-to-proceed criteria below.

### Signal to proceed from Phase 0 to Phase 1

Do not advance until all are true:

1. Deterministic replay works reliably. Same seed produces byte-identical
   traces across 1000+ runs, across machines, across `Debug` and
   `ReleaseSafe` builds.
2. The twice-and-compare detector catches deliberately-injected
   non-determinism. Verify with at least three distinct non-determinism
   sources (time, thread id, allocator address).
3. The linter catches deliberately-injected banned calls.
4. We can articulate clearly why each interface exists and what invariants
   it maintains.
5. The code is clean enough that another Zig developer can understand the
   architecture in under 30 minutes of reading.
6. We still find the problem interesting. If Phase 0 felt like drudgery,
   the 12-month timeline will kill the project. Be honest about this.

If any are false, either fix it or reconsider the project.

---

## Non-negotiable engineering principles

These are hard rules. Do not relax them without a recorded discussion.

### 1. Determinism is the product

Every line asks: "could this introduce non-determinism?" If yes, stop.
Sources to be especially careful of:

- `std.time.*` — banned outside of `ProductionClock`. Enforced by linter.
- `std.Random` without an explicit seed — banned. Enforced by linter.
- `std.hash_map.AutoHashMap` iteration order — randomized in some Zig
  versions. Use explicit ordering or sorted iteration in simulated code.
- Allocator address dependence — never use pointer identity as a hash key
  or ordering.
- Threads — banned in simulated code. Enforced by linter.
  `std.Thread.spawn`, `std.Thread.Pool`, etc.
- Filesystem calls outside `Disk` interface — banned. Enforced by linter
  once `Disk` lands in Phase 1.
- Network calls outside `Network` interface — banned. Enforced by linter
  once `Network` lands in Phase 2.
- Environment variables, command-line args in simulated code — suspect.
- Hash functions that use random seeds — use our seeded variants.

### 2. Zero production overhead

The sim path must vanish in release builds. Use `comptime` switches and
verify via disassembly. Add a CI job that checks sim-mode symbols are
absent from release binaries.

### 3. Allocator discipline

Every allocation goes through an explicit allocator parameter. No hidden
`std.heap.page_allocator`. No global state. Simulator uses a deterministic
allocator; production uses whatever the user passes in.

### 4. Fail loudly

Assertions on in all build modes, including release. Invariant violation
crashes immediately with a clear message. Follows TigerStyle; appropriate
for a correctness-focused library.

### 5. No dependencies

Marionette depends only on Zig's standard library. Every transitive
dependency is another thing that could break determinism. Default answer
to "do we need dep X?" is no.

### 6. Library, not platform

We do not intercept syscalls, override libc symbols, fork the compiler,
or patch transitive dependencies. Users write deterministic code against
our interfaces. If a user's problem can't be solved within those
constraints, they are not our user.

---

## Style conventions

- Follow the Zig standard library's style. `snake_case` for functions and
  variables, `PascalCase` for types.
- Prefer explicit over clever. Readability wins over terseness.
- Comments explain _why_, not _what_.
- Every public function has a doc comment with at least one line.
- Test names are descriptive: `test "clock advances deterministically
under sim mode"` not `test "clock"`.
- Files under 500 lines where possible. Split by responsibility.
- No `TODO` without a tracking issue number.

## Directory layout

```
marionette/
├── CLAUDE.md                  # this file
├── README.md                  # public-facing description
├── build.zig
├── build.zig.zon
├── .references/               # ignored local checkouts of reference repos
│   └── README.md              # tracked manifest and clone commands
├── src/
│   ├── root.zig               # top-level public API
│   ├── world.zig
│   ├── clock.zig
│   ├── random.zig
│   ├── tidy.zig               # linter library module (scan logic)
│   ├── main_tidy.zig          # linter executable entry point
│   └── build_support.zig      # addTidyStep helper for user build.zigs
├── examples/
│   └── rate_limiter.zig
└── tests/
    ├── determinism.zig
    ├── fuzz.zig
    └── tidy_self_check.zig
```

---

## How to work with Claude Code on this project

When starting a session, assume Claude has read this file. Don't re-explain
the whole project unless context seems missing.

When proposing changes, follow this protocol:

1. **Check the roadmap.** Is this task in the current phase? If not, ask
   before doing work.
2. **Respect the principles.** If a change could introduce non-determinism,
   flag it clearly before writing code.
3. **Small commits.** One task per commit with a clear message. We want
   to bisect failures later.
4. **Tests before features.** For a new interface, write the determinism
   test first. If it passes trivially, the test is wrong.
5. **Ask when unsure.** This is a correctness project. Always better to
   ask "should I handle this edge case?" than paper over it.

Questions to ask when designing an API, in order:

1. Does this preserve determinism?
2. Does this compile to zero cost in release?
3. Is this the simplest API that serves the use case?
4. Does this match how TigerBeetle's VOPR handles the same problem? (Not
   because they're always right, but because they've thought about it
   longer than we have.)

---

## References

Primary sources we're building on:

Local reference checkouts live under `.references/`. The directory is ignored
and has a `README.md` which lists suggested repositories and
clone commands. Use these repos for UX and implementation inspiration, but do
not vendor them or copy code into Marionette.

When working on a design question, consult `.references/` deliberately:

- `.references/tigerbeetle` for Zig style, deterministic simulation
  discipline, VOPR concepts, `tidy` patterns, and correctness-oriented docs.
- `.references/foundationdb` for the original DST model, simulation concepts,
  and long-running fault-injection culture.
- `.references/turmoil` for network simulation UX and service-test ergonomics.
- `.references/shuttle` for replay UX and for explaining why Marionette is
  not a concurrent scheduler.
- `.references/madsim` for platform-vs-library tradeoffs and API comparison.

References are for learning and comparison. Do not copy implementation code.
If a Marionette design is materially inspired by a reference, explain that
in comments or docs in our own words.

- TigerBeetle's VOPR docs:
  https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/internals/vopr.md
- TigerBeetle's architecture:
  https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md
- TigerBeetle's tidy.zig (inspiration for our linter approach):
  https://github.com/tigerbeetle/tigerbeetle/blob/main/src/tidy.zig
- Will Wilson's Strange Loop 2014 talk on FoundationDB DST.
- Matklad on Zig comptime and idioms: https://matklad.github.io/
- Phil Eaton on DST:
  https://notes.eatonphil.com/2024-08-20-deterministic-simulation-testing.html
- Antithesis' DST primer:
  https://antithesis.com/docs/resources/deterministic_simulation_testing/
- S2's writeup on adopting DST: https://s2.dev/blog/dst

Related libraries (for API inspiration and to understand what we're
competing against):

- MadSim (Rust, platform-approach): https://github.com/madsim-rs/madsim
- Turmoil (Rust): https://github.com/tokio-rs/turmoil
- Shuttle (Rust, concurrent data structures): https://github.com/awslabs/shuttle
- Iofthetiger (Zig) — TigerBeetle's IO library, extracted.
