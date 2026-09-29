# Campaigns

A campaign runs many seeds unattended and keeps the evidence for every distinct
failure it finds. It takes the same config as `runSimCase`:

```zig
var evidence = try std.Io.Dir.cwd().openDir(io, "campaigns", .{});
defer evidence.close(io);
var summary = try mar.runCampaign(.{
    .allocator = allocator,
    .seed = 0xC0FFEE,
    .simulate = mar.World.SimulateOptions{},
    .init = Service.init,
    .scenario = Service.scenario,
    .checks = &Service.checks,
    .watchdog = mar.WatchdogOptions{},
}, .{
    .io = io,
    .cases = 10_000,
    .time_budget_ns = 10 * std.time.ns_per_min,
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
`Summary.stop_reason` says which. The budget is checked after each case, so at
least one case always runs. With a watchdog, one case can overrun the budget by
at most two `run_timeout_ns`: one per execution.

## Surviving bad cases

Set the config's `watchdog` so each case runs in an isolated worker. A case that
hangs, livelocks, or crashes its worker becomes an ordinary `non_yielding`,
`livelock`, or `worker_crashed` failure and the campaign moves on. Without a
watchdog, a case that never yields or exits the process stops the campaign too.

Runner errors that belong to one case, such as a completed result larger than the
watchdog's `result_capacity`, are listed in `Summary.errors` and the campaign
continues. Configuration errors (invalid checks, seed schedules, or watchdog
options) and host `OutOfMemory` stop the campaign and return the error.

## Distinct failures and evidence

Failures are grouped by full failure identity: kind, error name, and check name,
as compared by `FailureFingerprint`. Each `CampaignFailure` records the first case
and seed that produced it, how many cases produced it, and whether it is
`reproducible`: a complete, exactly replayed failure whose capsule executes and
which `reduceSimCase` can reduce. Watchdog-terminated failures are not
reproducible because the killed worker never published a complete tape.

With `artifacts`, the campaign creates a new directory and refuses to reuse an
existing one. It writes the first occurrence of each distinct failure to
`failure-<fingerprint digest>` using the [artifact layout](reduction-and-explanation.md#ci-artifact-directories):
a trace, a replay capsule when the failure is reproducible, and a manifest.
Diagnostics for non-reproducible failures are kept without a capsule.
`campaign.json` is written last with the counts, stop reason, elapsed time,
distinct failures, and case errors; a directory without it is from a campaign
that did not finish.

To reproduce a retained failure in a fresh process, decode its `replay.json` and
call `replaySimCase` with the same harness and `ReplayIdentity`.
