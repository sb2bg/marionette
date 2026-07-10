# External Findings With Marionette

This document records characterized findings from running Marionette against
external systems. "Finding" is intentionally broader than "confirmed upstream
bug": it can include real SUT bugs, simulator-boundary counterexamples, harness
or model bugs, and positive robustness results worth preserving.

The item-level ledger for defects in Marionette itself is
[`SIMULATOR_FINDINGS.md`](SIMULATOR_FINDINGS.md).

A finding belongs here only after the failing state is understood well enough to
separate:

- a real system-under-test bug,
- a harness or model bug,
- a simulator boundary or intentionally unphysical stress case,
- and a positive result where a plausible bug class was tested and did not
  reproduce.

This distinction matters. Marionette's credibility comes from characterizing the
result before making a claim about it.

## Classification

- **Confirmed SUT bug:** The SUT violates a normal correctness or durability
  invariant, ideally with a small deterministic reproduction.
- **Simulator boundary:** Marionette demonstrated a behavior outside the
  guarantees expected from normal hardware or production deployments. Useful as
  a simulator capability test, but not counted as a SUT bug.
- **Positive robustness result:** Marionette exercised a plausible bug class and
  the pinned SUT held under the tested model.
- **Harness/model bug:** The checker or workload was wrong. These can be
  recorded if the lesson matters, but they are not SUT bugs.

## Summary

| ID        | Project | Classification     | Trigger                                      | Result                                                                                             | Upstream status                   |
| --------- | ------- | ------------------ | -------------------------------------------- | -------------------------------------------------------------------------------------------------- | --------------------------------- |
| KVDB-001  | kvdb    | Confirmed SUT bug  | Metadata-loss crash / corrupt root page      | Reopen could trust an invalid B-tree root and hit debug assertions instead of reporting corruption | Not fixed upstream                |
| KVDB-002  | kvdb    | Confirmed SUT bug  | No-fault randomized synced puts              | Leaf insert could overwrite an existing entry's payload, making a committed key disappear          | Not fixed upstream                |
| KVDB-003  | kvdb    | Confirmed SUT bug  | No-fault delete-heavy model workload         | Leaf delete rebalancing broke B+tree separator/order invariants, making unrelated keys unreachable | Not fixed upstream                |
| XITDB-001 | xitdb   | Simulator boundary | 7-byte-sector torn committed-size header     | A sub-field tear can corrupt recovery, but the field is structurally atomic at realistic sectors   | Characterized; not a reported bug |
| XITDB-002 | xitdb   | Positive result    | 512/4096-byte data-region torn/reorder sweep | Acknowledged modeled history survived the tested realistic data-region crash faults                | No SUT bug found in this profile  |
| DUSTY-001 | dusty   | Confirmed SUT bug  | Server crash with a pooled keep-alive conn   | Client connection pool never evicts a dead connection; the client can never recover                | Fixed upstream                    |
| DUSTY-002 | dusty   | Confirmed SUT bug  | Graceful shutdown with an active handler     | `listen` drain busy-spins forever: the drain event latches set and is never reset                  | Fixed upstream                    |

## Shared Harness Pattern

The highest-value external-SUT tests were not just "does it survive a crash"
checks. They were model-checked workloads with a concrete oracle for
acknowledged data:

- committed and synced writes must survive;
- deleted keys must stay deleted;
- unsynced work may be absent, but must not become corrupt partial state;
- corruption must be reported as an error rather than causing assertion crashes;
- and expected failures are used only for closed, characterized results.

That oracle found normal correctness bugs first, then made the same scenarios
usable under fault injection.

## KVDB Findings

The kvdb harness used Marionette's simulated disk with 4096-byte sectors and
tested the database through its public API. The key addition was an exact model
oracle:

- Every committed and synced transaction is recorded in a model.
- After reopen or crash/restart, every modeled key must be present with the
  exact expected value.
- Deleted keys must be absent.
- The test suite does not hide uncharacterized failures behind expected-failure
  markers.

The faulted tests reused the same model checks under lost writes, torn writes,
reordered writes, lost metadata, and disk write errors.

### KVDB-001: Invalid Root Page Was Trusted After Metadata Loss

**Project:** kvdb

**Classification:** Confirmed SUT bug

**Trigger:** Marionette metadata-loss crash injection, plus a direct regression
test that opened a database file with invalid metadata and a zeroed root page.

**Symptom:** kvdb could reopen a file whose metadata was invalid, rewrite only
the metadata page, and leave the B-tree root page uninitialized or corrupt.
Subsequent lookup traversal trusted the root page header and child pointers. In
debug builds this could hit assertions in B-tree traversal instead of returning
a clean corruption error.

**Why this is a real bug:** Storage engines must treat pages read from disk as
untrusted. A crash or metadata loss can leave a file in an older, shorter, or
otherwise inconsistent state. Even if a specific simulator schedule is debated,
a direct zero/garbage-root repro demonstrates the core bug: persisted B-tree
page bytes were trusted before structural validation.

**Fix direction:** Recovering from invalid metadata should initialize both the
metadata and root pages, reset the next-page ID to match that initialized
layout, and validate node headers, key ranges, and child page IDs before lookup
trusts persisted root bytes.

**Regression coverage to keep with a fix:**

- Metadata crash faults report corruption without panicking.
- Invalid metadata initialization writes an empty root page.
- Garbage root page reports `CorruptedData` without panicking.

### KVDB-002: Leaf Insert Overwrote an Existing Payload

**Project:** kvdb

**Classification:** Confirmed SUT bug

**Trigger:** No fault injection. A randomized synced-put model test shrank to a
small deterministic insertion sequence, including:

```text
put k-0000
put k-0037
put k-0074
put k-0016
```

After inserting a key before the end of a non-full leaf, a previously committed
key could become unreachable or return incorrect data.

**Root cause:** `insertLeaf` shifted `KeyInfo` entries before computing the next
payload write offset. While the header still contained the old key count, the
shift hid the displaced last entry from `getNextDataOffset()`. The new payload
could then be written over the old last entry's payload bytes.

**Why this is a real bug:** This reproduces with ordinary committed writes and
no crashes or injected disk faults. Marionette found it through exact model
checking, not through an exotic fault schedule.

**Fix direction:** Compute the payload offset before shifting `KeyInfo` entries.
That preserves the previous logical entries while the insert opens a slot.

**Regression coverage to keep with a fix:**

- Randomized synced model, no faults, `fsync_policy = .always`.
- Randomized synced model, no faults, `fsync_policy = .batch`.

### KVDB-003: Leaf Delete Rebalancing Broke B+tree Invariants

**Project:** kvdb

**Classification:** Confirmed SUT bug

**Trigger:** No fault injection. The delete-heavy model test inserted 96 synced
keys, then ran a deterministic delete sequence. Before any crash phase, deleting
`k-0088` at step 67 made unrelated key `k-0050` disappear from lookup results,
even though the model had not deleted it.

**Root cause:** Leaf delete rebalancing treated B+tree separators like stored
leaf entries and handled borrowing with incorrect ordering and separator update
rules:

- Leaf merge inserted the parent separator as a fake leaf record with an empty
  value.
- Borrowing from the left sibling appended the borrowed key to the end of the
  underflowing right leaf, even though that key belongs at the beginning.
- Borrowing from the right sibling updated the parent separator before removing
  the borrowed key from the sibling.

These mistakes could leave leaves out of sorted order or leave parent separators
pointing at the wrong child boundary. Once that happened, binary search and
internal routing could miss committed keys.

**Why this is a real bug:** The failure occurs before crash or fault injection.
It is a plain correctness bug in normal delete rebalancing.

**Fix direction:** Leaf merge should concatenate only real leaf entries.
Borrowed leaf entries should be inserted in sorted order, and parent separators
should be updated from post-borrow child state.

**Regression coverage to keep with a fix:**

- Delete-heavy exact model verification before the crash phase.
- Delete-heavy exact model verification after Marionette crash/restart fuzzing.

## xitdb Findings

The xitdb harness is pinned to
`f86134242e4d265cddfb0dbebd4d2d6dd4967274` and runs through Marionette's
deterministic `std.Io.File` backend with a model oracle for acknowledged
history.

### XITDB-001: Torn Committed-Size Header Boundary

**Project:** xitdb

**Classification:** Simulator boundary

**Trigger:** A deliberately non-realistic 7-byte sector model tore the 8-byte
committed file-size field at bytes 28-35 during an unacknowledged write.

**Symptom:** A torn write over the committed-size header could make recovery
truncate or read according to a corrupted committed size, causing recovery to
fail against the previously acknowledged model state.

**Why this is not counted as a SUT bug:** The committed-size field is at fixed
offset 28-35, wholly inside sector 0 for realistic 512- and 4096-byte sector
atomicity. Marionette reproduced the boundary only by making the atomic write
granularity smaller than a real storage device's sector. That makes it a useful
demonstration of the simulator's torn-write capability and of xitdb's implicit
atomicity assumption, but not a hardware-realistic xitdb data-loss bug.

**What Marionette proved:** The harness can shrink and characterize a recovery
counterexample precisely enough to distinguish "real SUT bug" from "simulator
boundary." This result should be described as a sub-field atomicity boundary,
not as xitdb data loss on normal disks.

### XITDB-002: Realistic Data-Region Torn/Reorder Sweep Held

**Project:** xitdb

**Classification:** Positive robustness result

**Trigger:** Realistic 512- and 4096-byte sector profiles with torn and
reordered data-region writes, while keeping the committed-size header within
normal sector atomicity.

**Result:** The pinned xitdb commit preserved acknowledged modeled history under
the tested profiles. The harness did not find a hardware-realistic data-region
recovery bug in this sweep.

**Why this is useful:** A clean result at realistic geometries is still
evidence. It says the initial header-boundary counterexample should not be
overclaimed, and it gives future sweeps a known baseline.

## dusty Findings

The dusty harness is pinned to dusty 0.1.0 and runs the unmodified HTTP/1.1
client and server through Marionette's deterministic `std.Io.net` backend
(`validation/dusty_http.zig`).

### DUSTY-001: Connection Pool Never Evicts a Dead Connection

**Project:** dusty

**Classification:** Confirmed SUT bug

**Trigger:** A healthy keep-alive fetch parks a connection in the client's
pool, then the server process dies (simulated `killProcess`; equivalent to a
real server restart or crash). Every subsequent fetch on the same client
fails.

**Symptom:** The pinned scenario shows three consecutive fetch attempts
failing with `WriteFailed` and zero new dials (`io.net.connect` count stays
at the healthy fetch's one). After a server restart, with the server provably
reachable, the same client still fails with the same error, while a fresh
client converges on its first attempt.

**Root cause:** `Client.fetchInternal`'s error path is
`errdefer self.pool.release(conn)`, and `ConnectionPool.release` only
discards connections marked `closing`. No write-failure path ever sets
`conn.closing = true` (only response-parsing and keep-alive-header paths
do). The dead connection is therefore released back into the pool, and
`acquire` scans LIFO, so every retry re-acquires the same dead connection
and fails at write time without dialing. The pool is permanently poisoned.

**Why this is a real bug:** Any server restart, idle-timeout close, or
network blip that kills a pooled connection between requests makes the
client permanently unable to reach that host until the whole client is
recreated. No fault model exotica is involved; this is the common case for
any long-lived HTTP client.

**Fix direction:** Mark the connection `closing` on write/flush failures
(and arguably on any transport-level error) before the errdefer release, or
have `release` validate liveness before pooling.

**Regression coverage:** `validation/dusty_http.zig` pins the poisoning
(three write-failed attempts, zero dials, identical failure after restart,
fresh-client convergence) across a seed sweep.

### DUSTY-002: Graceful-Shutdown Drain Busy-Spins on a Latched Event

**Project:** dusty

**Classification:** Confirmed SUT bug

**Trigger:** Cancel `Server.listen` (graceful shutdown) while at least one
connection handler is still active, after at least one other connection has
closed at any earlier point in the server's life.

**Symptom:** Under Marionette's cooperative scheduler, the whole simulation
livelocks at 100% CPU with virtual time frozen; the drain loop never
suspends, so no other task (including the handler that would decrement the
connection count) can run. On a preemptive production runtime the same code
busy-spins a core until the remaining handlers happen to finish.

**Root cause:** The drain loop waits on
`last_connection_closed.waitTimeout(io, 100ms)`. `std.Io.Event` latches: it
is set on the first connection close and never reset. `Event.waitTimeout`
on a set event returns immediately by contract, so once any connection has
ever closed, the drain's "wait" is a no-op and the
`while (active_connections != 0)` loop spins hot. The 100ms timeout that
would otherwise propagate `error.Timeout` (dusty's shutdown-timeout
contract) never fires either, because the wait never blocks.

**Why the existing tests missed it:** dusty's shutdown-timeout contract
only manifests when the drain actually blocks, which requires that no
connection ever closed before shutdown. Marionette's earlier hung-shutdown
scenario met that condition by accident; the pool scenarios were the first
to shut down after a connection had already closed. Under preemptive
threads the spin also makes progress eventually, so it reads as "shutdown
is slow," not "shutdown is broken."

**Fix direction:** Reset the event before re-checking the count, or replace
the latched event with a condition-variable-style wait that re-arms, or
count down through the timeout budget explicitly.

**Simulator note:** A task loop with no suspension point is invisible to a
cooperative scheduler: the deadlock detector cannot fire because the task
is runnable, and no watchdog task can run because nothing yields. Detecting
hot loops (a step or instruction budget between suspension points) is
recorded as a roadmap candidate; until then, harness code must avoid
triggering this dusty path (the pool scenarios tear the server down with
`killProcess` instead of cancellation).

## Takeaways

- Named external SUTs are most useful when paired with an independent oracle.
- Fault injection is valuable, but ordinary no-fault model checking found two
  kvdb correctness bugs before crash fuzzing did.
- Expected-failure tests should describe closed, understood behavior. They
  should not hide uncharacterized failures.
- Simulator-boundary findings are worth recording when they explain what the
  simulator can explore and what production hardware does or does not guarantee.
