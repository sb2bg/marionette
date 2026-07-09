# Changelog

## Unreleased

- Adds the pinned lazy beanstalkz validation (`validate-beanstalkz`): the
  unmodified `g41797/beanstalkz` work-queue client runs against a
  harness-owned in-memory beanstalkd speaking the text protocol over
  simulated `std.Io.net` streams. Covers a produce/consume round trip with
  bury/kick transitions and the pinned `error.Timeout` empty-reserve
  contract, sequential connection churn (connect, put, quit,
  `shutdown(.both)`, close) drained in FIFO order, a blocking
  `reserve-with-timeout` parked across a five-second virtual publish
  delay, and a server-process crash under a parked reserve that surfaces
  the pinned `error.CommunicationFailure` reset contract before a
  registered restart recovers on a fresh incarnation. All scenarios replay
  byte-identically from the same seed.

## v0.5.0 - 2026-07-06

- Adds the one-shot liveness transition `sim.transitionToLiveness(core)`,
  following the VOPR `transition_to_liveness_mode` shape: zeroes every
  probabilistic simulator fault rate (process dynamics, network lossiness,
  clog and partition dynamics, disk faults, allocation faults), restores
  links, clogs, and node-down state inside the core, restarts a crashed
  disk, and revives killed core processes through their registered
  lifecycles, while non-core failures stay permanent. Trace-visible as
  `liveness.transition` and `network.liveness_restore`; a second call
  asserts as harness misuse, and recoverable validation errors (invalid
  core node, killed core process without a registered lifecycle) are
  checked before any state changes so a failed call stays retryable.
- Keeps consumer builds lean: Marionette's build script registers only the
  public modules when built as a dependency, so depending on Marionette no
  longer fetches its lazy validation SUTs (xitdb, mailbox, Ochi, dusty, and
  their transitive dependency trees) or runs their build scripts, one of
  which shelled out to git and printed `fatal: not a git repository` noise
  into consumer projects.
- Documents the user-facing API surface with contract-level doc comments
  (errors, trace events, alignment and determinism rules): `Env`
  authorities, the network/disk/process/allocation simulator controls and
  their option structs, `SimProfile`, `SimCase` accessors, endpoints, the
  disk handle, and the message pool, so editor hover shows the same
  contracts as the API doc.
- Adds simulated `netLookup` for address literals: IPv4/IPv6 literals and
  RFC 6761 `localhost` names resolve deterministically through the std
  queue protocol (trace event `io.net.lookup`), so an unmodified
  `std.http.Client` request against a simulated server succeeds, including
  the `localhost` two-candidate `connectMany` race where the v6 loopback
  attempt fails cleanly and v4 wins. Real DNS, `/etc/hosts`, and search
  domains remain explicitly unsupported (`error.UnknownHostName`), and the
  fetch replays byte-identically from the same seed.
- Settles two simulator-wide conventions and documents them in the
  determinism doc: a disabled fault (zero rate) consumes no randomness and
  emits no trace, so `Env.buggify` at `.never()` no longer draws or records;
  and misaligned `runFor` durations assert as harness misuse across
  `SimControl` and network control instead of returning
  `error.InvalidDuration`. The buggify change can shift seed streams for
  workloads that rolled zero-rate hooks, which is why it lands inside the
  0.5 release boundary.
- Adds the structural disk crash trigger `control.disk.crashAfterOps(n)`:
  the disk crashes at the operation boundary after `n` more data/metadata
  operations, trace-visible as `disk.fault kind=armed_crash`. The xitdb
  crash-fault fuzzer now arms the trigger instead of measuring an
  undisturbed victim run and sleeping to a tick offset: `measureVictimTicks`
  is gone, each fuzz case runs once instead of twice, and the shrink test's
  crash-point scan is self-bounding via the `passed_no_window` outcome.
- Adds guarded fiber stack-overflow diagnostics on POSIX guard-page targets:
  task fibers register their guard regions with task/process metadata, and a
  `SIGSEGV`/`SIGBUS` handler on the alternate signal stack writes a targeted
  stderr diagnostic (task id, owning process, configured stack size, the
  `task_stack_size` fix) when a fault lands in a registered guard, then
  chains to the previously installed handler so Zig's Debug trace still
  shows the fault site. Non-guard faults chain through unchanged. Subprocess
  tests cover both the overflow diagnostic and the non-fiber fall-through;
  embedders opt out with `simulate(.{ .fiber_overflow_diagnostics = false })`.
- Adds the deterministic allocation authority core: `Env.allocator()` returns
  an app-facing `std.mem.Allocator`, simulation wraps the harness allocator
  with deterministic fail-after, live-byte quota, and BUGGIFY allocation
  faults configured through `control.allocation`, and allocation decisions
  are traced without raw addresses. Production envs return the caller-provided
  backing allocator with no faults.
- Adds the memtable allocation-pressure example: allocation failure is a
  modeled branch with a clean-rejection oracle, a planted commit-before-
  allocate bug the checker catches under deterministic OOM, and a
  `buggify_rate` fuzz scenario.
- Documents the allocation authority in the API and trace-format docs,
  including the decision that all allocation operations are traced by
  default.
- Raises the default scheduler task stack from 256 KiB to 1 MiB. dusty's
  Debug-mode client fetch path needs more than 640 KiB, and fiber stacks are
  lazily paged mmap regions on guard-page targets, so the increase costs
  address space rather than resident memory.
- Adds a pinned lazy dusty validation that runs the unmodified HTTP
  client/server library through simulated `std.Io.net` streams: routed GET
  and POST echo over one keep-alive connection, an exact response oracle,
  and byte-identical same-seed replay.
- Re-scopes the 0.6 roadmap target from production `Endpoint(Message)`
  transport to SUT-driven deterministic `std.Io.net` depth, and defers the
  production transport chain to 0.7.
- Adds cooperative cancellation following `std.Io`'s protocol: `Future.cancel`
  and `Group.cancel` arm a one-shot request that delivers `error.Canceled` at
  the task's next cancellation point (`checkCancel`, `futexWait`, `sleep`,
  `netAccept`, `netRead`, `netWrite`), interrupting cancelable parks
  immediately. `recancel` re-arms, `swapCancelProtection` defers delivery,
  uncancelable waits defer to the next point, and group members are canceled
  in ascending task order. Requests and deliveries are trace-visible as
  `scheduler.cancel_request` / `scheduler.cancel_deliver`.
- Runs the dusty validation through dusty's real `Server.listen` accept loop:
  multi-connection accept, keep-alive reuse, and two cancel-driven shutdown
  shapes, both with byte-identical same-seed replay. A clean shutdown
  delivers `error.Canceled` in the accept park with nothing left to drain;
  a hung-connection shutdown leaves a keep-alive handler parked in a read,
  so dusty's drain times out and its deferred group cancel sweeps the parked
  handler.
- Adds dusty HTTP fault scenarios with an oracle: partition before response
  and mid-response through futex handshakes, pin dusty's observed
  `error.Timeout` contract under a severed link, heal and retry with a fresh
  client, require exact response bodies, reject short-success partial chunked
  responses, and sweep every chunk cut point across deterministic seeds.
- Fixes closed-handle retirement when a canceled net wait loses a race with
  a concurrent close: the canceled accept/read paths now retire closed idle
  handles exactly like the woken paths.
- Defines the recovery-window vocabulary (durability boundary, durable truth,
  recovery window, destructive budget) in the disk fault model, with the KV
  example as the worked case: crash fault classes apply only to pending
  writes, and damaging durable truth requires an explicitly destructive
  fault. Adds the probabilistic KV recovery search: a window checker that
  asserts synced records recover exactly while unsynced records may be
  absent or exact but never damaged, held across a 32-seed fuzz, plus a
  seed search that finds the planted magic-only recovery bug as
  `DamagedRecordAccepted`.
- Adds the KV compatibility validation, a local storage surrogate that uses
  `std.Io` WAL appends, file sync, tmp-file compaction through rename,
  directory sync, WAL clear/delete, and crash-point fuzzing across aligned and
  misaligned sectors. Its oracle accepts either physical incarnation around
  pending metadata while requiring recovered key/value durable truth to
  converge exactly.
- Expands the xitdb crash-fault profile into a fuzzer with shrinking. Each
  case runs a seed-planned transaction workload, commits a durable setup
  boundary, then crashes the disk at a seed-varied simulated time while the
  final transaction runs mid-commit as a cooperative task, applying exactly
  one crash fault class (lost, torn, or reordered) to pending writes across
  512/4096-byte sectors. Failures shrink greedily to a 1-minimal transaction
  and operation sequence rendered as a readable repro. The shrinker
  demonstrably reduces the characterized XITDB-001 sub-field torn-header
  boundary (7-byte sectors) to at most three transactions.
- Fixes operation-scoped buffer leaks when a task is killed while parked in
  a disk-latency wait: sector scratch and resolved-path buffers held across
  `std.Io` file-operation suspension points now register with the backend
  and killed-task survivors are swept after task retirement, since a killed
  fiber never runs its defers.
- Widens the fiber stack guard from one page to a 256 KiB PROT_NONE region,
  so Debug-mode stack frames larger than a page fault at the overflow
  instead of silently corrupting neighboring mappings. The widened guard
  immediately caught a latent overflow in the dusty hung-shutdown
  validation that the single-page guard had missed. Adds
  `SimulateOptions.task_stack_size` so a simulation can raise the
  scheduler task stack for deep SUT call chains; the dusty validation now
  uses 8 MiB.

## v0.4.0 - 2026-06-30

- Adds named simulation profiles (`baseline`, `swarm`, `replay`, and
  `performance`) that expand into run metadata, simulator options, and explicit
  runtime-control application. The replicated-register swarm now uses the
  shared profile and reports the expanded profile values in traces and failure
  summaries.
- Adds a durable-broadcast bug-search test that finds the planted
  broadcast-before-sync bug under probabilistic crash-loss faults while keeping
  the deterministic single-seed failure for readable traces.
- Adds scheduler-backed `Io.Group` async/concurrent/await/cancel behavior with
  deterministic task ownership, reuse, and process-kill cleanup.
- Adds the simulated directory operations needed by ordinary storage engines:
  absolute and handle-relative paths, create/open/access/stat, iteration,
  directory syncing through `File.sync`, and process-coordinated blocking and
  non-blocking advisory file locks. Directory namespace state now lives in
  `SimDisk`, so processes share it and crash metadata faults apply to it.
- Adds a pinned lazy Ochi validation that starts the unmodified store, ingests
  a line, flushes index/data tables, queries the line, crashes and reopens the
  store, and verifies the same line through recovery.
- Fixes a same-directory `SimDisk.rename` metadata allocation leak.
- Fixes sector read-modify-write handling so short `std.Io` writes retain their
  logical file length across crashes, and atomic rename discards pending writes
  belonging to the replaced destination.
- Fixes cross-process file-lock rekeying on rename so open lock holders release
  the renamed path and source/destination waiters are preserved.
- Adds process-scoped simulation `std.Io` backends with stable per-node
  identity, shared listener/connection registration, and process-local futex
  namespaces.
- Adds logical process lifecycle controls: `killProcess`, registered process
  initializers, and restart semantics that discard volatile state while
  preserving durable disk state.
- Fixes cross-process async closure cleanup so awaits release task closures
  through the owning backend.
- Requires callers to pass an allocator to `Production.init`, removing the
  production default to `std.heap.smp_allocator`.
- Retires completed scheduler task records after completion while preserving
  stable task counts.
- Narrows the public/internal module boundary so backend coordinators, task
  runtimes, process runtimes, and teardown hooks are kept under explicit
  internal roots.
- Adds a release-symbol readiness check that verifies simulation-only symbols
  are absent from release binaries.
- Adds a contributor-facing repository layout guide.

## v0.3.0 - 2026-06-16

Marionette's third release makes deterministic `std.Io` execution the primary
integration tier:

- Adds scheduler-backed `Io.async`, `Io.concurrent`, and `Io.await`, including
  task-side suspension and main-context scheduler driving.
- Routes simulated sleep and disk-operation latency through scheduler
  deadlines, so a long I/O operation cannot skip an earlier timer.
- Adds traced deterministic `Io.random` / `Io.randomSecure` and compares replay
  outcomes symmetrically, including failures.
- Runs the pinned `g41797/mailbox` validation and the bounded-queue capability
  validation entirely through ordinary `std.Io` tasks.
- Adds an external-style fixed-frame KV client/server written only against
  `std.Io.net`, with deterministic happy-path replay and a
  partition/timeout/heal retry scenario.
- Adds `zig build validate-std-io-net-kv` plus runnable correct and planted-bug
  scenarios. The exact oracle catches duplicate mutation application even when
  the final value is unchanged.
- Suspends `std.Io.net` accept and read operations cooperatively and models
  stream latency, send-time loss, delivery-time partitions, healing, retry
  timeouts, and graceful close.
- Models disk crashes as process restarts for the file layer: open handles are
  invalidated and cached lengths are refreshed from durable disk state.
- Fixes Zig 0.16 fiber context-switch constraints and optimizer visibility,
  adds unwind-safe entry stacks, eagerly reclaims completed fiber stacks, and
  adds POSIX guard pages with a portable stack-canary fallback.
- Splits disk, network, and `std.Io` internals into focused modules and narrows
  obsolete top-level API aliases.
- Makes failed simulation construction roll back teardown registrations,
  enforces one simulation per world, and shares rooted logical-path validation
  between simulated and production disks.
- Makes production directory sync fail explicitly with
  `error.DirectorySyncUnsupported` rather than reporting durability without
  performing it.
- Disables x86_64 Windows fiber execution until the Win64 entry trampoline has
  execution coverage; the disabled target remains compile-checked.
- Expands CI to Debug, ReleaseSafe, and ReleaseFast validation, macOS execution,
  a Win64 fiber compile check, and bounded job timeouts.

Known limits remain: fibers are cooperative rather than preemptive; one world
hosts one simulation; current `std.Io.net` is still a narrow TCP-stream subset;
`Io.Group`, cooperative cancellation points, cross-process production
networking, and complete host filename parity remain roadmap work.

## v0.2.0 - 2026-06-02

Marionette's second tagged release adds the cooperative-concurrency tier:

- Adds the `std.Io.fiber`-backed scheduler stack: deterministic task spawning,
  seeded runnable selection, blocking wait sets, futex wakeups, and timed futex
  waits.
- Runs a real Zig cooperative-concurrency library, `g41797/mailbox` pinned at
  `d30ff69f1fa0288e1a8cb96b24ae3b552739f490`, unmodified through Marionette's
  scheduler-backed `std.Io`.
- Verifies same-seed replay for Mailbox timeout, same-deadline timeout
  ordering, and send/wake paths through `zig build validate-mailbox`.
- Keeps the concurrency claim deliberately scoped: cooperative `Mutex` /
  `Condition` code is modeled; arbitrary OS thread scheduling, memory-model
  interleavings, `async` / `await`, cancellation, allocator simulation, and
  production scheduler parity remain roadmap work.
- Keeps the v0.1 storage story intact: `zig build validate-xitdb` still runs
  the pinned xitdb validation target against the deterministic file backend.

## v0.1.0 - 2026-05-29

Marionette's first tagged release demonstrates the core thesis:

- Runs a real Zig storage engine, `xit-vcs/xitdb` pinned at
  `f86134242e4d265cddfb0dbebd4d2d6dd4967274`, unmodified through Marionette's
  deterministic `std.Io` file backend.
- Replays deterministically from a seed and validates xitdb against a modeled
  randomized workload.
- Confirms, on the pinned xitdb commit and the current validation profile, that
  acknowledged file-backed transactions survive lost-write crash injection.
- Checks xitdb old read-only moments after later writes and verifies the same
  modeled workload against both SimDisk and host `std.Io`.
- Surfaces a precise sub-field-granularity torn-write counterexample: xitdb's
  committed-size field lives at bytes 28-35, so it is structurally atomic for
  512- and 4096-byte sectors, but Marionette can demonstrate the recovery
  boundary with a deliberately non-realistic 7-byte sector.

This is still a `0.x` API. There is no stability guarantee before 1.0. The
intended-stable surface today is `World`, `Env`, `Control`, `SimCase`,
`runSimCase` / `expectSim*`, `runCase` / `expect*`, `Disk`, `SimDisk`,
`RealDisk`, `Production`, `Recorder`, and the app-facing `Endpoint(Message)`
shape. Everything else may change as the simulator grows.

Known scope limits for this release:

- `Mutex`, `Condition`, futex waits, and arbitrary OS thread scheduling are not
  modeled.
- Production network transport is partial; cross-process production endpoints
  remain roadmap work.
- Allocator simulation and shrinking are planned, not shipped.
