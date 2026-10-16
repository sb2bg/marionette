# Campaigns

A campaign runs many seeds unattended and keeps the evidence for every distinct
failure it finds. It takes the same config as `runSimCase`:

```zig
var evidence = try std.Io.Dir.cwd().openDir(io, "campaigns", .{});
defer evidence.close(io);
var summary = try mar.runCampaign(.{
    .allocator = allocator,
    .seed = 0xC0FFEE,
    .simulate = mar.World.SimulateOptions{ .step_budget = 100_000 },
    .init = Service.init,
    .scenario = Service.scenario,
    .checks = &Service.checks,
    .watchdog = mar.WatchdogOptions{},
}, .{
    .io = io,
    .cases = 10_000,
    .time_budget_ns = 10 * std.time.ns_per_min,
    .reduction = .{ .max_attempts = 256 },
    .artifacts = .{ .parent = evidence, .name = "nightly-2026-09-29", .identity = identity },
});
defer summary.deinit();
```

## Seeds and stopping

Case `i` uses the same seed as `expectSimFuzz` iteration `i` for the config's
`seed`, so a campaign and a fuzz test over the same base explore the same seeds
in the same order. Every case is recorded and exact-replayed, as in `runSimCase`.

A campaign stops after `cases` cases, when `max_failures` failing cases have been
seen, or when `time_budget_ns` of host monotonic time has elapsed.
`Summary.stop_reason` says which. Limits are checked before every case but the
first, so a new campaign always runs at least one case. The time budget covers
reduction too. With a watchdog, one case can overrun the budget by at most two
`run_timeout_ns`, one per execution, plus that case's reduction.

## Surviving bad cases

Two bounds keep one case from stopping the campaign, and they answer different
problems:

- A [step budget](run.md#step-budget) on `SimulateOptions` turns code that keeps
  yielding forever (sleeping, retrying, waking peers) into a deterministic
  `step_budget_exceeded` failure. Its tape is complete, so it is retained with a
  capsule and can be reduced like any other failure.
- The config's `watchdog` runs each case in an isolated worker. A case that never
  yields, livelocks past the host deadline, or crashes its worker becomes a
  `non_yielding`, `livelock`, or `worker_crashed` failure and the campaign moves
  on. Without a watchdog, a case that never yields or exits the process stops the
  campaign too.

Set both for unattended runs, with a step budget well below what the watchdog's
host deadlines allow, so yielding hangs stay reproducible.

Runner errors that belong to one case, such as a completed result larger than the
watchdog's `result_capacity`, are listed in `Summary.errors` with `phase = .run`
and the campaign continues. Configuration errors (invalid checks, seed schedules,
or watchdog options) and host `OutOfMemory` stop the campaign and return the
error.

## Distinct failures and evidence

Failures are grouped by full failure identity: kind, error name, and check name,
as compared by `FailureFingerprint`. Each `CampaignFailure` records the first case
and seed that produced it, how many cases produced it, and whether it is
`reproducible`: a complete, exactly replayed failure whose capsule executes and
which can be reduced. Watchdog-terminated failures are not reproducible because
the killed worker never published a complete tape.

With `artifacts`, the campaign creates a new directory and refuses to reuse an
existing one. It writes the first occurrence of each distinct failure to
`failure-<fingerprint digest>` using the [artifact layout](reduction-and-explanation.md#ci-artifact-directories):
a trace, a replay capsule when the failure is reproducible, and a manifest.
Diagnostics for non-reproducible failures are kept without a capsule.

## Reduction

Set `reduction` to reduce the first occurrence of each new reproducible distinct
failure, using the same bounded delta debugging as
[`reduceSimCase`](reduction-and-explanation.md#reduce-a-failure). The campaign
reuses the case's recorded report instead of running it again. Later
occurrences of a known failure are only counted. Incomplete watchdog failures
are never reduced.

The failure's `reduction` records candidate `attempts`, original and remaining
decision groups, whether the result is `one_minimal`, whether a smaller failure
was `minimized`, and the host time it took. When a smaller verified failure is
found, its trace, capsule, and manifest go in the failure directory's `reduced`
subdirectory. A reduction that hits a runner error is listed in
`Summary.errors` with `phase = .reduction`, and the original evidence is kept.

## Metrics

`Summary.metrics()` returns `CampaignMetrics`:

- `cases_per_second`: executed cases per second of host time outside reduction;
- `distinct_failures` and `reproducible_failures`;
- `reduced_failures`: failures whose reduction found a smaller failure;
- `reduction_attempts` and `reduction_elapsed_ns`: the total reduction cost.

The journal stores the same numbers under `metrics` at every checkpoint. They
are derived from the journal's other fields and ignored when it is read back.

## Journal and resume

`campaign.json` is the campaign's journal: identity, base seed, planned and
executed cases, counts, elapsed host time, metrics, distinct failures with their
reductions, and case errors. It is replaced atomically when the campaign starts,
before the case after a new distinct failure, at least every
`checkpoint_interval_ns` (one second by default), and when the campaign stops.
`stop_reason` is `null` while the campaign runs, so a journal with a null stop
reason is from a campaign that was killed.

Set `resume_existing = true` to continue in an existing directory, whether the
campaign was killed or stopped by a limit. The config seed, `cases`, and
`ReplayIdentity` must match the journal, or the call returns
`IncompatibleCampaign`; a campaign that ran every case returns
`CampaignFinished`. Limits may change between invocations. The time budget
covers the whole campaign, including earlier invocations. `Summary.start_case`
is the first case this invocation ran; all counts are campaign totals.

Cases after the last checkpoint run again, and counts come from the same
checkpoint, so none are counted twice. If a kill landed after a failure
directory, or its `reduced` subdirectory, was written but before the checkpoint
that lists it, resume keeps the directory when its manifest is complete and
rewrites it otherwise. A kill during reduction reruns that case and its
reduction.

## Replay and reduce from a fresh process

Retained evidence needs only the pinned harness, not the process that found it.
`loadCampaignSummary` reads a journal without running anything, including a
killed campaign's (its `stop_reason` is null):

```zig
var dir = try evidence.openDir(io, "nightly-2026-09-29", .{});
defer dir.close(io);
var summary = try mar.loadCampaignSummary(allocator, io, dir);
defer summary.deinit();

for (summary.failures) |failure| {
    if (!failure.reproducible) continue;
    var failure_dir = try dir.openDir(io, failure.artifact_name.?, .{});
    defer failure_dir.close(io);
    const bytes = try failure_dir.readFileAlloc(io, "replay.json", allocator, .unlimited);
    defer allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(allocator, bytes);
    defer capsule.deinit();

    var replayed = try mar.replaySimCase(harness, &capsule, identity);
    defer replayed.deinit();
    var reduced = try mar.reduceCapsule(harness, &capsule, identity, .{});
    defer reduced.deinit();
}
```

`harness` supplies the allocator, `init`, `scenario`, and `checks`; runtime and
simulation options come from the capsule. `reduceCapsule` first replays the
capsule exactly, then reduces it under the capsule's own options. With the same
attempt budget it repeats the campaign's reduction step for step, including the
minimized trace.

## Validation on real systems

`zig build validate-campaigns` exercises the whole workflow on pinned,
unmodified xitdb (storage and crash recovery) and redis.zig (network retries,
connection pooling, and cooperative tasks). Each workload runs as three
processes: a campaign that kills itself partway through, a fresh process that
resumes it, and a fresh process that replays every retained capsule and reduces
it again from the capsule alone.

| Workload | Oracle | Expected outcome |
| --- | --- | --- |
| `xitdb-acknowledged-history` | Acknowledged transactions survive exactly; the crashed victim is absent or whole | No failures |
| `xitdb-victim-durable-mutant` | Also demands the never-acknowledged victim | One reproducible, reduced failure |
| `redis-at-least-once` | Acknowledged INCR values come from real, ordered applications | No failures |
| `redis-exactly-once-mutant` | Every applied INCR is acknowledged exactly once | One reproducible, reduced failure |

The mutants are deliberately over-strong oracles that exercise the failure path
on real code. They are not bug claims. Each process prints a metrics line.
`-Dcampaign-cases` sets the case count (48 by default) and `-Dcampaign-dir` the
evidence directory (`zig-out/campaigns` by default).

CI runs the step in every optimization mode and uploads the evidence directory.
The nightly workflow runs 5,000 cases per workload and uploads the evidence and
metrics for 30 days. A long run already found a false positive in the xitdb
oracle; see XITDB-003 in the [findings](https://github.com/sb2bg/marionette/blob/main/FOUND_BUGS.md).
