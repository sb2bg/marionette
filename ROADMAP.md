# Roadmap

This file contains current and future work. Completed work belongs in
`CHANGELOG.md`; confirmed external bugs belong in `FOUND_BUGS.md`; open
simulator defects belong in `SIMULATOR_FINDINGS.md`.

## North Star

Marionette should make failures in Zig systems code reproducible, explainable,
and reducible while keeping application code shaped around `std.Io` and narrow
application-owned capabilities.

## Next: 0.9: Honest Network

0.8 delivered dependable campaigns: bounded runs that survive bad cases,
deterministic step budgets, deduplicated and reduced evidence, resume after a
kill, fresh-process replay and reduction, fault coverage, and an end-to-end
validation on pinned storage and network workloads
(`zig build validate-campaigns`). 0.8.1 made reduction strip faults instead of
injecting them, added crash-point sweeps, and recorded today's network behavior
as characterization tests. 0.8.2 fixed terminal future awaits, scoped sweep
accounting, and reduction of automatic fault schedules. 0.8.3 replaced the disk
contract with `portable_v2`, which keeps data and namespace durability separate,
and added named crash profiles, effect requirements, and paired missing-sync
workloads; see `CHANGELOG.md`.

The network turns faults into immediate, invented errors and lets endpoints read
each other's state, so the bugs partitions really cause (hangs, half-open
connections, late replies, ambiguous retries) cannot happen in simulation.
Connecting into a partition fails at once even with a 10 s timeout, a peer's
close or kill reaches it across a partition with no delay, and 1% loss kills a
stream. Two pinned validations (`std_io_net_kv` and dusty's partition scenarios)
pass only because the simulator invents a timeout error for clients that set
none.
That is a trustworthy-models defect, and fixing it changes network semantics and
API, so it lands before the stabilization candidates start.

- **Hosts own addresses.** Per-host IPv4 and IPv6 addresses, port tables, and
  ephemeral ranges; binding another host's address fails with
  `AddressUnavailable`; `accept` reports the client's real address; a simulated
  DNS resolves host names. Behind `address_model = .per_host_v1`.
- **A push-based fabric.** Directed links with latency and loss policies, one
  network event queue the scheduler waits on, and per-socket buffers, so
  delivery no longer waits for readers and one stalled connection cannot starve
  another.
- **TCP-lite.** Handshake, cumulative ACKs, receive windows, timed
  retransmission with backoff, and FIN and RST on the wire. A fault by itself
  produces silence; errors come only from mechanisms with Linux-shaped timing:
  refusal, retry exhaustion, keepalive, or an explicit reject fault. Behind
  `semantics = .tcp_v1`, with `.linux` and `.compressed` timing profiles.
- **Faults as handles.** `partition`, `isolate`, `cut`, and `degrade` return
  faults with ids, a disruption mode (drop, hold, slow, reject), an optional
  duration, and one composition rule; healing one fault leaves the others.
  Include isolate-one and partial partitions, which failure studies show
  trigger most partition bugs. Today's calls map onto these.
- **Explain every packet's fate.** Trace sends, drops, holds, and deliveries with
  their reason and fault id, and print a `netstat` table of sockets and active
  faults on deadlock, watchdog, and check failures. Use the common diagnostic
  vocabulary developed through 0.10.
- **Versioned semantics.** Capsules record the network model and replay rejects
  a mismatch. Convert validations that relied on invented errors to real
  application timeouts, then flip the defaults with a changelog entry.
- **Decide `Endpoint(Message)`.** raftz builds its cluster tests on it: promote a
  small stable subset or document a migration path to `std.Io.net`. Retention
  requires a declared delivery/ownership contract, non-advancing polling, and
  rejection of pointer/slice payloads by default; any borrowed-memory behavior
  must be an explicit opt-in.

Land the model through three acceptance gates:

1. Host-owned addresses and binds, correct accepted-peer identities, and buffer
   isolation between unrelated connections.
2. Scheduler-driven packet delivery, composable directed faults, and a traced
   explanation for each packet's fate.
3. TCP silence, retry, flow control, and teardown behavior, with explicit
   application timeouts in the pinned validations.

Exit when the characterization probes behave as Linux TCP would under `tcp_v1`,
every pinned validation passes without invented errors, a missing application
timeout surfaces as a reported deadlock, and the performance baseline holds.

## 0.10: Harness And Diagnostics

The runner works, but the pinned real-world workloads do not use it: 9 of the 11
files in `validation/` call `World.init` directly and compare traces by hand, so
the best evidence gets no capsules, reduction, campaigns, or crash-point sweeps.
They also fail from task bodies by panicking (91 panic sites). This milestone
settles the common harness workflow, with those workloads as its acceptance
test. Final API freeze follows 0.11's host-storage integration.

- **Run the validations through the runner.** Port beanstalkz and dusty first;
  what they cannot express (multi-node setup, outcome assertions, failing a run
  from a task) is the gap to close.
- **Publish one complete replicated-service example.** A three-node example
  uses public runner APIs for durable state, socket communication, managed
  restart, a planted invariant failure, capsule replay, reduction, and
  preservation as a regression. Extend it with independent power loss in 0.11.
- **Fail a run from a task.** Make a task error a scenario failure with a report
  instead of a panic, through error-returning `std.Io` futures or a case helper.
- **One typed harness.** Replace `config: anytype` with a harness type built once
  from the app, scenario, and checks, driving run, fuzz, replay, reduction,
  campaigns, and sweeps. Replay then cannot be handed different checks, and
  simulation options can default.
- **Infallible recording.** Recording errors land in every caller's signature
  although production recording cannot fail. Record the first failure on the
  world and fail the run at the next boundary; give `Recorder` a sink so
  production code can send events somewhere. Make escaped structured fields
  the common path and validate literal format components at compile time where
  practical, so ordinary string values cannot break trace syntax.
- **One process-control surface.** Choose between `sim.killProcess`,
  `control.process.kill`, and `ManagedProcess`.
- **Keep `World` an engine detail.** Move the choices harnesses need
  (`chooseBool`, `chooseIntLessThan`, `randomBytes`) onto `Control`, stop
  exposing mutable `World` fields, and return precise error sets where a control
  interface has one implementation. Public harness inputs such as misaligned
  durations and clock overflow return descriptive errors.
- **Reproduce without editing code.** Rerun a failing fuzz or campaign seed
  through a build option, fill `ReplayIdentity` from the build, and replay a
  downstream capsule from the command line.
- **Group the root exports** into namespaces such as `mar.disk`, `mar.net`, and
  `mar.replay`, after the adopter workflow establishes the useful boundaries.

### Diagnostics Deliverables

Land independent reporting improvements during 0.9; 0.10 closes the complete
diagnostic workflow. 0.8.3 already separates crash injections, eligible
pending state, and crash effects in sweep results.

- **Explain the failure boundary.** Determinism mismatches show the first
  differing events from both traces; scenario failures include a bounded tail.
  Support focused node, operation, and file histories without requiring a GUI.
- **Correlate faults across models.** Record fault and decision identities,
  node/incarnation, affected operation, modeled cause, and mapped `std.Io`
  error. Application observation and recovery require explicit harness evidence;
  effect counters alone do not establish either.
- **Make choices readable.** Include choice-site identities in text traces.
  Summaries can filter empty wakes while raw evidence retains causal events.
- **Distinguish unsupported models from application failures.** A strict
  capability mode marks a run unsupported when code touches an unmodeled
  operation, even if the application catches its I/O error. Intentional
  feature-absence testing remains explicitly selectable.

Exit when the ported validations need no `World.init`, no task panics, and no
hand-compared traces; the replicated-service example completes the workflow
from failure to preserved regression; and failures expose the relevant decisions
and operations.
The workflow is settled, with the final public contract completed in 0.11.

## 0.11: Independent Host Storage

Give each host its own storage namespace and crash domain, building on 0.9's
host identities and 0.10's process-control surface.

- **Scope volumes and crashes.** Assign storage and pending writes to explicit
  host domains, with sharing only when requested. Hosts can use the same local
  paths independently. Host power loss resolves only that domain's pending
  state and stops its processes; process restart remains a separate operation.
- **Carry domains through evidence.** Capsules, fault records, resource checks,
  and crash-point sweeps identify the affected domain. Shared-domain failures
  have an explicit, tested scope.
- **Exercise replicated storage.** Extend the canonical example and pinned
  Raft validation with independent power loss, recovery, replay, and reduction.
  Settle the application and harness handles before stabilization.

Exit when crashing A leaves B and C alive with their durable and pending storage
intact, explicit shared domains fail together as declared, and retained
multi-node failures exact-replay and reduce. Independent clock skew and drift
remain deferred.

## Stabilization And 1.0 Acceptance

With 0.8.3's storage gaps closed, once 0.9 flips the network defaults and 0.10
and 0.11 settle the workflow and host-storage APIs, a release-candidate phase
should close the following evidence gates. 1.0 commits to the documented
deterministic `std.Io` subset and testing workflow.

- **Stable public contract:** identify supported application/harness APIs and
  explicitly experimental surfaces; publish deprecation and compatibility rules.
  Complete two consecutive stabilization candidates without breaking that API,
  with a downstream upgrade exercised in CI.
- **Trustworthy models:** contract and host-differential tests cover supported
  semantics. Mutation tests demonstrate that claimed bug classes are exposed:
  known-correct workloads pass and deliberately broken ones fail. Unsupported
  capabilities are distinguishable from modeled application errors. No
  unresolved defects may invalidate determinism, ownership, or correctness
  results on supported targets.
- **Durable evidence:** complete corpus failures exact-replay from a fresh
  process with pinned build/SUT/toolchain identity; incompatible or malformed
  artifacts and disk/network model mismatches are rejected. Reduction preserves
  the full failure identity and produces an executable, replay-verified capsule
  within its budget. Cross-build replay is not required; artifact versioning
  and retention rules are explicit.
- **Operational reliability:** campaigns enforce budgets, retain partial failures,
  deduplicate and resume correctly, and leave no leaked workers or owned resources.
  Keep the pinned external validations release-blocking and require a
  consecutive 30-day nightly run with no unexplained simulator failures or hangs.
  Ochi is suspended until upstream supports Zig 0.17; restore it to the
  release-blocking set once it builds again.
- **Independent usability:** at least two independently maintained real projects
  can integrate, diagnose, replay, and preserve regressions using published APIs
  and documentation without editing Marionette internals.
- **Support and performance:** publish the exact OS/architecture/Zig/optimization
  matrix, enforce it in CI, and test clean package installation. Publish measured
  scaling across node, connection, task, and event counts, tracking peak memory,
  trace/tape bytes, throughput, and reduction cost. Establish regression budgets
  from those workloads and declare evidence-size limits and overflow behavior.
  Bounded or streamed capture must preserve original failure evidence, including
  nondeterminism mismatches that may not regenerate on demand.

PCT, bounded schedule exploration, linearizability checking, semantic coverage,
campaign sharding, network nemesis and swarm profiles, targeted packet rules,
datagrams, new transports, and broader platform support require concrete
workload evidence. They are not prerequisites for a narrow, dependable 1.0.

## Deferred Harness Work

- Add allocation-site stacks and generic user-resource tracking beyond the
  existing simulated-handle checks.
- Add independent host clock skew and drift for lease and timeout workloads;
  independent storage crash domains are scheduled in 0.11.
- Reduce individual occurrences after site-level removal when a workload needs
  finer minimization. Preserve full failure identity and executable replay;
  today's minimality guarantee remains relative to whole site groups.
- Add bounded or streamed trace retention when scaling measurements exceed the
  declared limits. Preserve captured evidence of the original execution rather
  than relying on regeneration after a nondeterminism failure.
- Build a network nemesis, per-seed swarm fault profiles, and targeted packet
  rules on 0.9's fault handles.
- Add datagrams, and rebuild `Endpoint(Message)` on them under a declared
  delivery contract, once a pinned workload needs UDP.
- Let `std.testing.fuzz` input drive simulator decisions, so coverage-guided
  fuzzing can steer faults and schedules. raftz runs its nightly WAL fuzzing
  this way, with Marionette only seeded from the fuzzer.

## Standing Decisions

### `std.Io` Is The Production Seam

Production-shaped SUT code accepts host `std.Io`; simulation substitutes the
deterministic backend. Marionette does not ship a production runtime or socket
bus. Harness fault powers stay out of application handles.

### Typed Messages Are Experimental

`std.Io.net` tests codecs, framing, partial I/O, stream lifecycle, and transport
glue. `Endpoint(Message)` explores protocol/state-machine behavior above the
wire. It is not a promise of production transport parity. 0.9 decides its
long-term status.

### Breadth Is SUT-Driven

UDP, Unix sockets, richer DNS, new storage profiles, extension hooks, and wider
protocol surfaces require evidence from a pinned SUT or concrete adopter.
Graphical debugging, DPOR, and scheduler rewrites wait for mature artifacts or
measurement.

### Model Contracts Must Expose Claimed Bugs

A named contract makes assumptions inspectable; agreement between its tests and
implementation is only part of the evidence. Supported bug classes also need
deliberately broken workloads that the model detects. Corrected semantics get
new identities, while older artifacts retain their pinned-build interpretation.

## Contribution Gate

Changes must pass debug, safe, and fast tests, formatting, tidy,
relevant target checks, and applicable external validations. Model changes need
contract/state-machine coverage and paired correct/broken workloads for the
affected guarantees; ownership-changing fallible paths need targeted failure
coverage. Public or semantic changes update the relevant contract documentation,
model identity, and replay compatibility checks.
