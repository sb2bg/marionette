# Reduction and Explanation

Marionette 0.7.1 builds on 0.7's pinned-build replay capsules. A failure can now
be checked at an explicit safe point, reduced to essential semantic groups,
explained with causal references, and saved as a CI artifact directory.

## Properties and action groups

A check name is its stable property ID. Choose one ID per invariant and preserve
it as the workload evolves. The failure fingerprint compares the complete
`kind`, `error_name`, and `check_name`; its 64-bit digest is a convenient label,
not the acceptance predicate. Give different properties distinct IDs rather
than relying on a generic scenario error to distinguish unrelated bugs.

```zig
const checks = [_]mar.StateCheck(Case){
    .{ .name = "service.at_most_once", .phase = .always, .check = safe },
};

fn scenario(case: *Case) !void {
    try case.action("background", background);
    try case.action("request", request);
    try case.action("retry", retry);
    try case.checkpoint("after.retry");
}
```

`checkpoint` IDs and action IDs use the semantic site grammar from
[Decision Tapes](decision-tapes.md). A checkpoint evaluates `.checkpoint` and
`.always` checks in declaration order. `.always` also runs after initialization
and after a successful scenario; `.both` covers those two lifecycle boundaries
only. The first failed property stays fatal even if the scenario catches its
error, repairs the state, or later returns a different error. Cleanup still runs.
Checks inspect state at caller-selected boundaries; they do not implicitly drain
tasks or run after every scheduler step.

An action is enabled in normal exploration. Its `action.<id>` boolean decision
controls whether the callback executes during replay or reduction. Put required
setup outside optional groups. A site repeated in a loop belongs to one group;
use distinct semantic IDs when operations should be removable separately.

## Reduce a failure

```zig
var reduced = try mar.reduceSimCase(.{
    .allocator = allocator,
    .seed = seed,
    .simulate = mar.World.SimulateOptions{},
    .init = App.init,
    .scenario = scenario,
    .checks = &checks,
    .watchdog = mar.WatchdogOptions{},
}, .{ .max_attempts = 256 });
defer reduced.deinit();

const report = reduced.report(); // borrowed until reduced.deinit()
const bytes = try mar.ReplayCapsule.encode(allocator, report, identity);
defer allocator.free(bytes);
```

The reducer first requires a reproducible failure with a complete tape. It uses
bounded delta debugging to omit groups of nonzero semantic sites. Omitted
scalar choices become zero/false; byte choices become zero-filled buffers.
Omitted actions therefore skip their callbacks. Other choices reuse the original
selection at the same site occurrence when the alternatives still match; new or
incompatible sites use generated values. This is candidate exploration, **not
exact replay**. Each candidate records a fresh tape and must pass an exact second
execution and preserve the original full failure fingerprint before acceptance.

`attempts` counts candidate runs (each includes replay). `remaining_groups`
counts retained original groups, not trace events or bytes. `one_minimal` means
no remaining single group can be omitted under this transformation; it does not
promise the globally smallest workload. If the attempt budget runs out, the best
verified result is returned with `one_minimal = false`. Use the normal watchdog
configuration to bound each candidate; an attempt count alone cannot stop a
non-returning scenario. Incomplete watchdog failures and mismatches cannot be
reduction baselines. Infrastructure errors abort reduction and release owned
results.

The minimized capsule contains the actual decisions, including disabled actions.
Replay it with the original harness and checks: no external removal mask or
modified workload is needed. Retain the pinned executable and build/SUT identity.

Run the complete example:

```sh
zig build run-example -- reduce-idempotency --seed 1234 --trace --expect-failure
```

It removes telemetry, retains the request and duplicate that cause the bug, and
prints the reduced property failure. The example is also part of `zig build test`.

## Causal events and operation spans

`EventId` is the existing world-global trace index. `Recorder.event(name, fields,
cause)` returns an optional ID; a disabled production recorder returns null.
A cause must reference an earlier event in the same world. The `cause` field is
reserved by this API. IDs come from events, never pointers or host thread IDs.

```zig
const accepted = try recorder.event("service.accepted", &.{}, null);
var operation = try recorder.beginOperation("request.commit", accepted);
_ = try operation.event("service.persisted", &.{});
try operation.end();
```

`operation.begin` starts the span; span events and `operation.end` reference its
begin event through `cause`. The explicit token remains associated with the
operation across task switches and can be used as the cause of another span.
Tokens borrow their recorder and must not outlive the world. Move tokens rather
than copying them. Ending a token twice, or appending to an
ended token, returns `OperationEnded`. On a failed operation, an unmatched begin
is useful diagnostic evidence; tracing does not automatically end or roll back
application operations.

Deadlocks retain sorted `scheduler.wait_state` diagnostics. If blocked tasks form
a cycle through modeled task-completion waits, `scheduler.deadlock_cycle` emits
one compact closed path, such as `tasks=0,1,0`. Timed waits are excluded. Arbitrary
futex, group, and I/O waits do not have unique known owners; they remain wait-state
diagnostics rather than speculative cycles.

## CI artifact directories

Pass `artifacts` to `runSimCase` (or its single-case expectation wrappers):

```zig
.artifacts = mar.ArtifactOptions{
    .io = host_io,
    .parent = artifact_parent,
    .name = "case-1234",
    .identity = identity,
},
```

The runner writes after completing both executions, outside simulator/watchdog
execution. It uses only caller-supplied host `std.Io` and `std.Io.Dir` capabilities.
By default only failures are saved; `include_passes` includes passing runs.
The name must be one relative ASCII component using letters, digits, `.`, `-`,
and `_`, excluding `.` and `..`. The parent must exist. Reusing a directory
returns `ArtifactAlreadyExists` instead of overwriting a previous failure.

Directories contain:

- `trace.txt` and, for mismatches, `second-trace.txt`;
- `replay.json` when the report is complete and reproducible;
- `manifest.json`, with build/SUT identity, expanded static simulator and runner
  options, failure identity, fingerprint, divergence diagnostics, and capsule
  availability. Runtime fault/process configuration remains visible in the trace.

The manifest is written last. Consumers should require a valid complete manifest;
a partial I/O failure may leave an unfinished directory. Incomplete or divergent
failures still produce diagnostic artifacts and explain why no capsule exists.
Host I/O errors return `ArtifactIoFailed`; encoding errors return
`ArtifactEncodingFailed`. Artifact I/O is not part of deterministic trace replay.
For fuzz campaigns, choose a separate directory per run and call
`writeRunArtifacts` on retained reports; automatic campaign directory naming is
part of the later Guided Exploration roadmap.

Save a minimized result with `mar.writeRunArtifacts(allocator, reduced.report(),
artifact_options)`. The `ReductionResult` owns both the original report and the
best accepted report; ordinary reports retain their existing ownership rules.

## Managed process restart/reopen

```zig
const process = try sim.manageProcess(Service, node, Service.open);
try sim.killProcess(node);
try sim.restartProcess(node);
const reopened = process.state() orelse return error.ProcessUnavailable;
```

`Service.open(env: mar.Env) !Service` creates volatile state and reopens durable
resources through the revived node's environment. A public `Service.deinit`
releases that state. The world owns the stable `ManagedProcess(Service)` object;
do not destroy it or retain a pointer from `state()` across a kill or restart.
Kill stops process tasks and handles before freeing application state. Restart
publishes a complete fresh service only after initialization succeeds; failed
reopen leaves no live state and can be retried. Duplicate registration is rejected.

The runner finishes managed processes after application cleanup and before
resource checks and trace capture, so cleanup is replay-verified. Direct world
users can call `sim.finishManagedProcesses()` at their own capture boundary;
world teardown also releases remaining managed state. Existing manually registered
`ProcessLifecycle` callbacks retain their default cleanup policy. Fault options
and automatic restart dynamics remain explicit through the existing controls.
