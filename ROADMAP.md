# Roadmap

This file contains current and future work. Completed work belongs in
`CHANGELOG.md`; confirmed external bugs belong in `FOUND_BUGS.md`; open
simulator defects belong in `SIMULATOR_FINDINGS.md`.

## North Star

Marionette should make failures in Zig systems code reproducible, explainable,
and reducible while keeping application code shaped around `std.Io` and narrow
application-owned capabilities.

## Next: 0.11: Independent Host Storage

0.8.3 corrected storage durability with `portable_v2`. 0.9 made the network
honest: TCP-lite over a push-based fabric, hosts that own their addresses,
faults as handles that produce silence, every packet's fate in the trace, and
`tcp_v1` as the default. 0.10 settled the harness workflow, with every pinned
validation on `mar.Harness`, a complete replicated-service example, escaped
structured recording, descriptive time errors, and failures that explain
their decisions, fault effects, and operations; see `CHANGELOG.md`.

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

With 0.8.3's storage gaps closed, 0.9's network defaults flipped, and 0.10's
workflow settled, once 0.11 settles the host-storage APIs, a release-candidate phase
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
- Remove the deprecated `legacy_v0` network semantics once its
  characterization and regression tests are ported to `tcp_v1`.
- Model TCP keepalive, congestion control, and Nagle's algorithm in a later
  `tcp_v2` once a pinned workload depends on them.
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
wire. It is not a promise of production transport parity. 0.9 kept it
experimental under a declared delivery and ownership contract and documented
the migration path to `std.Io.net`; it will be rebuilt on datagrams once a
pinned workload needs UDP.

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
