# Roadmap

This file contains current and future work. Completed work belongs in
`CHANGELOG.md`; confirmed external bugs belong in `FOUND_BUGS.md`; open
simulator defects belong in `SIMULATOR_FINDINGS.md`.

## North Star

Marionette should make failures in Zig systems code reproducible, explainable,
and reducible while keeping application code shaped around `std.Io` and narrow
application-owned capabilities.

## Current: 0.7.1 — Release Reduction And Explanation

Consolidate the completed reduction, property, artifact, and managed-process
work with the pinned PostgreSQL and Redis client validations. Finish the
release gates in `docs/releasing.md` before tagging. The acceptance record is
`NEXT_RELEASE.md` in the repository root.

## Proposed Next: 0.7.2 — Bounded Cleanup

- Isolate process supervision and managed-state ownership from `World`, retaining
  the current public entry points and lifecycle semantics.
- Share runner configuration/check preparation across normal runs, replay, and
  reduction without adding another public runner abstraction.
- Clarify application, harness, and experimental/model APIs in the documentation;
  defer breaking export changes to an explicitly planned compatibility change.
- Make local verification work after dependencies and generated files exist.
- Record a small repeatable baseline for run throughput, trace/tape memory, and
  reduction cost before attempting performance rewrites.

Exit when these concrete changes are complete, the full validation matrix is
green, and representative trace/decision fixtures and artifact formats are
unchanged. Continue enforcing pinned-build identity checks. Avoid model expansion
and unrelated module churn in this release. Findings that require semantic changes
must be identified separately rather than hidden in a refactor.

## Proposed 0.8 — Dependable Campaigns

- Run bounded seed ranges with per-run watchdogs and a total campaign budget.
  Add deterministic execution-step budgets for yielding workloads; preserve
  external containment for code that never yields.
- Save failure identities, traces, and complete replay capsules automatically;
  retain explicit partial diagnostics for killed or crashed workers.
- Deduplicate by full failure identity, resume interrupted campaigns, and upload
  artifacts from CI. Apply bounded reduction only to eligible complete failures.
- Exercise the complete campaign-to-regression workflow on existing real storage
  and network/concurrency workloads with independent correctness oracles.
- Track throughput, distinct failures, reproduction success, and reduction cost.

Exit when an unattended campaign can survive a bad case, retain its evidence,
resume its remaining work, and replay/reduce eligible failures from a fresh
process using the pinned harness. Demonstrate this on at least two external
workloads, including storage and network/concurrency behavior.

## Stabilization And 1.0 Acceptance

A 0.9 or release-candidate phase should close the following evidence gates.
1.0 commits to the documented deterministic `std.Io` subset and testing workflow.

- **Stable public contract:** identify supported application/harness APIs and
  explicitly experimental surfaces; publish deprecation and compatibility rules.
  Complete two consecutive stabilization candidates without breaking that API,
  with a downstream upgrade exercised in CI.
- **Trustworthy models:** contract and host-differential tests cover supported
  semantics; unsupported operations fail explicitly. No unresolved defects may
  invalidate determinism, ownership, or correctness results on supported targets.
- **Durable evidence:** complete corpus failures exact-replay from a fresh
  process with pinned build/SUT/toolchain identity; incompatible or malformed
  artifacts are rejected. Reduction preserves the full failure identity and
  produces an executable, replay-verified capsule within its budget. Cross-build
  replay is not required; artifact versioning and retention rules are explicit.
- **Operational reliability:** campaigns enforce budgets, retain partial failures,
  deduplicate and resume correctly, and leave no leaked workers or owned resources.
  Keep the seven pinned external validations release-blocking and require a
  consecutive 30-day nightly run with no unexplained simulator failures or hangs.
- **Independent usability:** at least two independently maintained real projects
  can integrate, diagnose, replay, and preserve regressions using published APIs
  and documentation without editing Marionette internals.
- **Support and performance:** publish the exact OS/architecture/Zig/optimization
  matrix, enforce it in CI, and test clean package installation. Publish measured
  scaling and resource limits with regression budgets for representative workloads.

PCT, bounded schedule exploration, linearizability checking, semantic coverage,
campaign sharding, new transports, and broader platform support require concrete
workload evidence. They are not prerequisites for a narrow, dependable 1.0.

## Deferred Harness Work

- Add allocation-site stacks and generic user-resource tracking beyond the
  existing simulated-handle checks.

## Standing Decisions

### `std.Io` Is The Production Seam

Production-shaped SUT code accepts host `std.Io`; simulation substitutes the
deterministic backend. Marionette does not ship a production runtime or socket
bus. Harness fault powers stay out of application handles.

### Typed Messages Are Experimental

`std.Io.net` tests codecs, framing, partial I/O, stream lifecycle, and transport
glue. `Endpoint(Message)` explores protocol/state-machine behavior above the
wire. It is not a promise of production transport parity.

### Breadth Is SUT-Driven

UDP, Unix sockets, richer DNS, new storage profiles, extension hooks, and wider
protocol surfaces require evidence from a pinned SUT or concrete adopter.
Graphical debugging, DPOR, and scheduler rewrites wait for mature artifacts or
measurement.

## Contribution Gate

Changes must pass Debug, ReleaseSafe, and ReleaseFast tests, formatting, tidy,
relevant target checks, and applicable external validations. Model changes need
contract/state-machine coverage; ownership-changing fallible paths need
targeted failure coverage. Public or semantic changes update the relevant
contract documentation and versioning.
