# Architecture

Marionette substitutes deterministic authorities at the same boundaries where
application code already performs I/O or waits. The application sees `std.Io`
and narrow sibling capabilities. The harness sees explicit simulator control.

## Execution Shape

```text
runSimCase
  -> World
     -> Env / std.Io                 application authority
     -> Control                      harness authority
     -> disk, network, scheduler     deterministic models
     -> decision tape                executable choices
     -> trace                        explanatory evidence
```

`runSimCase` constructs this graph twice. It initializes app state from `Sim`,
executes the scenario, runs named checks, and deinitializes app state. The first
ordinary execution records semantic choices; the second exact-replays them and
compares traces. Failures remain owned data in `RunReport`.

## Authorities

`Env` contains application-facing I/O, allocation, disk, recording, and
BUGGIFY. `Control` contains time movement and fault injection. This separation
prevents production code from accidentally acquiring crash, partition, or
scheduler powers.

Prefer passing the smallest application capabilities. Code that only needs
files and trace events should accept `std.Io`, `std.Io.Dir`, and `Recorder`
rather than storing `Env`.

## Deterministic `std.Io`

The simulated backend implements the subsets needed by current validations:

- clocks, sleeps, randomness, async/concurrent tasks, groups, cancellation,
  futures, futexes, mutexes, and conditions;
- file and directory operations over the disk model;
- TCP-shaped streams, listeners, connects, reads, writes, deadlines, and
  process-scoped handles over the network model.

Unsupported operations fail closed. Marionette does not intercept arbitrary
host syscalls or make ambient nondeterminism reproducible.

## Scheduling And Time

Tasks run cooperatively on guarded fibers. A task switches only at modeled I/O,
wait, or explicit scheduler boundaries. Virtual time moves through `tick` or
`runFor`; host wall time is not consulted by simulated application code.

The scheduler is deterministic for a seed. It does not model OS preemption or
the CPU memory model, so ordinary thread, sanitizer, integration, and platform
testing remain necessary.

## Fault Models

Disk, network, allocation, and process models share the world's random stream
and trace. Disabled probabilistic faults consume no draws. `runFor` stops at
scheduled fault boundaries so automatic changes happen at their exact virtual
times.

Disk recovery follows the named `portable_v1` contract. Network streams share
bounded queues and byte-pool capacity. Allocation traces use counters and
sizes, never addresses.

## Process Lifecycles

Network and I/O handles are process-scoped. Killing a process cancels its
tasks, closes its resources, and invokes its registered lifecycle callback.
Restart reruns the initializer against surviving durable state. Harness-owned
application memory must be explicitly reset in the lifecycle callback.

## Decisions And Tracing

Decision entries identify a semantic site, logical time, microstep, preceding
trace event, typed alternatives, and selected value. Every trace event has a
global index. Dynamic text is percent-escaped and simulator traces avoid
addresses, wall-clock values, unordered iteration, and unstable error
formatting. The tape controls replay while the trace explains and verifies the
result.

## Production Boundary

Production-shaped libraries receive host `std.Io`, a root directory, and an
optional recorder. `Production` composes those host capabilities, but
Marionette is not a production runtime and does not ship a socket transport.

Typed `Endpoint(Message)` is an experimental protocol-modeling surface. It is
not wire parity; socket-facing code should use `std.Io.net`.


## Shared Filesystem Metadata

A simulation's process registry owns one file metadata store. Descriptor access
mode, cursor, lock ownership, and process lifetime remain local; the shared lock
table is keyed by stable file identity. Rename needs no lock-path rekeying. The
simulated disk is
the authority for identity, visible length, and modification time, including
pending writes. A non-suspending identity lookup refreshes metadata and resolves
paths after direct disk mutations. Custom disks may omit this optional lookup;
they retain the cached adapter contract. Crash recovery still rediscovers
stale metadata under the named disk semantics.

## Owned Execution Results

The runner normalizes and owns runtime configuration once across both executions.
Each execution returns one owned trace, decision tape, completion flag, and
pass/failure outcome (`execution.zig`). The comparator creates the public report
and owns shared metadata once. `watchdog.zig` handles worker isolation and
bounded transport; `execution_codec.zig` supplies the versioned payload shared
with persistent capsules. Worker termination explicitly marks an incomplete tape.

The redundant fixed packet runtime and its private `EventQueue` were removed.
Typed endpoints and streams exercise the active shared network runtime; useful
legacy contract tests now run against that implementation.
