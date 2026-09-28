# Performance Baseline

Run the fixed workloads without changing simulator semantics:

```sh
zig build baseline -Doptimize=ReleaseFast
```

The command emits one JSON line. It warms each path once, then measures 10,000
seeds starting at `0xC0FFEE`, using the host monotonic clock outside simulation.
Run five times without concurrent builds and compare median elapsed times on the
same machine, Zig version, target, optimization, and allocator. Compilation,
warmup, and JSON output are excluded. Report accounting and destruction are
included. Each ordinary run includes recording plus an exact second execution.

The workloads are intentionally small:

- **KV recovery:** the existing probabilistic WAL crash/recovery example with an
  independent recovery-window property. Every seed must pass exact replay.
- **Reduction:** the existing planted duplicate-application failure, with a
  256-candidate budget. Every seed must reach a one-minimal result with two
  essential action groups. Cost includes the original run and every candidate's
  exact second execution. This workload takes five candidates per reduction.

The JSON records event and decision counts plus total retained trace and tape
bytes. `trace_bytes` is the first execution's trace length. `tape_bytes` is
`entries.len * @sizeOf(Decision)` plus owned site-ID and random-byte lengths.
These count retained report storage, not allocator headers, configuration,
transient candidate storage, process RSS, or guarded fiber stacks. The reduction
row reports original and minimized storage separately; the result retains both.

## Recorded Measurement

The initial baseline was captured on 2026-09-22 with Zig 0.16.0, ReleaseFast,
aarch64-macos, Apple M1 Pro, using the process-init general-purpose allocator.
The workload was added to v0.7.1 (`8fb0fa3`) before the cleanup, then repeated
against the 0.7.2 development tree after validation completed. Raw samples and
source hashes are in `benchmarks/results/0.7.2-aarch64-macos.json`.

| Median of five repetitions | Before cleanup | After cleanup |
| --- | ---: | ---: |
| 10,000 KV runs | 203.810 ms | 205.138 ms |
| KV runs/second | 49,065 | 48,748 |
| 10,000 reductions | 255.098 ms | 262.079 ms |
| Microseconds/reduction | 25.510 | 26.208 |

Five samples are too few to call these differences significant. Event counts,
decisions, retained sizes, and reduction attempt counts match exactly before and
after the cleanup:

| Retained data per result | KV recovery mean | Reduction original | Reduction minimized |
| --- | ---: | ---: | ---: |
| Trace bytes | 3,855 | 725 | 699 |
| Tape bytes | 216 | 334 | 334 |
| Decisions | 1.76 | 3 | 3 |
| Events | 51.4 | 14 | 13 |

Disabling telemetry retains an explicit disabled-action decision, so this
reduction shortens the trace while retaining the same tape allocation size.
Larger storage, network/concurrency, and campaign workloads need their own
measurements before setting regression budgets.
