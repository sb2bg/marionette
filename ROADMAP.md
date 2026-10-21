# Roadmap

This file contains current and future work. Completed work belongs in
`CHANGELOG.md`; confirmed external bugs belong in `FOUND_BUGS.md`; open
simulator defects belong in `SIMULATOR_FINDINGS.md`.

## North Star

Marionette should make failures in Zig systems code reproducible, explainable,
and reducible while keeping application code shaped around `std.Io` and narrow
application-owned capabilities.

## Next: 0.8.1

0.8 delivered dependable campaigns: bounded runs that survive bad cases,
deterministic step budgets, deduplicated and reduced evidence, resume after a
kill, fresh-process replay and reduction, fault coverage, and an end-to-end
validation on pinned storage and network workloads
(`zig build validate-campaigns`). 0.8.1 fixes what keeps that evidence from
being trustworthy and removes the friction the first public adopter hit.

- **Zero means no fault.** Every probabilistic fault roll (network drops, disk
  faults, allocation and application BUGGIFY) fires when the roll is below the
  numerator, so a zero roll injects the fault. Reduction replaces removed
  decisions with zero and skips sites already at zero, so it adds faults and can
  never remove one that fired. Fire only when the roll is at least
  `denominator - numerator`, record the change as a decision-model version, and
  prove that reduction strips a planted fault.
- **Network characterization tests.** Check in the network probes (connect into
  a partition, a reply sent during a partition, close and kill during a
  partition, loss on an established stream, the same port bound on several
  nodes, a stalled reader starving an unrelated connect) as tests that record
  today's behavior, so 0.9 changes each expectation deliberately. The original
  probes ran on 0.7.2 with Zig 0.16; rerun them on Zig 0.17 first.
- **No shared-pool starvation on connect.** Take connection probes off the
  world-global stream buffer pool, so one stalled reader cannot fail an
  unrelated connect with `SystemResources`.
- **Crash-point sweeps.** Run a scenario once per disk crash point
  (`crashAfterOps(k)`) until the operation completes, through `runSimCase`, so
  each point gets exact replay and retained evidence. raftz writes this loop by
  hand four times over raw `World.init`.
- **Restart without a placeholder lifecycle.** Revive a node's I/O after a disk
  crash without registering a do-nothing `ProcessLifecycle`.
- **Directory sync through `std.Io`.** Document opening a directory as a `File`
  and calling `sync`, which the simulated backend already routes to directory
  durability, so durable code does not need the `Disk` capability for it.

## 0.9: Honest Network

The network turns faults into immediate, invented errors and lets endpoints read
each other's state, so the bugs partitions really cause (hangs, half-open
connections, late replies, ambiguous retries) cannot happen in simulation.
Connecting into a partition fails at once even with a 10 s timeout, a peer's
close or kill reaches it across a partition with no delay, and 1% loss kills a
stream. Two pinned validations (`std_io_net_kv` and dusty's partition scenarios)
pass only because the simulator invents a `Timeout` for clients that set none.
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
  faults on deadlock, watchdog, and check failures.
- **Versioned semantics.** Capsules record the network model and replay rejects
  a mismatch. Convert validations that relied on invented errors to real
  application timeouts, then flip the defaults with a changelog entry.
- **Decide `Endpoint(Message)`.** raftz builds its cluster tests on it: promote a
  small stable subset or document a migration path to `std.Io.net`.

Exit when the characterization probes behave as Linux TCP would under `tcp_v1`,
every pinned validation passes without invented errors, a missing application
timeout surfaces as a reported deadlock, and the performance baseline holds.

## Stabilization And 1.0 Acceptance

After 0.9 flips the network defaults, a release-candidate phase should close the
following evidence gates. 1.0 commits to the documented deterministic `std.Io`
subset and testing workflow.

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
  Keep the pinned external validations release-blocking and require a
  consecutive 30-day nightly run with no unexplained simulator failures or hangs.
  Ochi is suspended until upstream supports Zig 0.17; restore it to the
  release-blocking set once it builds again.
- **Independent usability:** at least two independently maintained real projects
  can integrate, diagnose, replay, and preserve regressions using published APIs
  and documentation without editing Marionette internals.
- **Support and performance:** publish the exact OS/architecture/Zig/optimization
  matrix, enforce it in CI, and test clean package installation. Publish measured
  scaling and resource limits with regression budgets for representative workloads.

PCT, bounded schedule exploration, linearizability checking, semantic coverage,
campaign sharding, network nemesis and swarm profiles, targeted packet rules,
datagrams, new transports, and broader platform support require concrete
workload evidence. They are not prerequisites for a narrow, dependable 1.0.

## Deferred Harness Work

- Add allocation-site stacks and generic user-resource tracking beyond the
  existing simulated-handle checks.
- Give each host its own disk and clock, so a host crash loses only that host's
  unsynced writes and leases can meet clock skew.
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

## Contribution Gate

Changes must pass debug, safe, and fast tests, formatting, tidy,
relevant target checks, and applicable external validations. Model changes need
contract/state-machine coverage; ownership-changing fallible paths need
targeted failure coverage. Public or semantic changes update the relevant
contract documentation and versioning.
