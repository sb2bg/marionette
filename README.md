<p align="center">
  <a href="https://sb2bg.github.io/marionette/">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/transparent_logo_text_dark.png">
      <source media="(prefers-color-scheme: light)" srcset="assets/transparent_logo_text.png">
      <img src="assets/transparent_logo_text.png" alt="Marionette" width="420">
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://sb2bg.github.io/marionette/">Docs and blog</a>
</p>

[![CI](https://github.com/sb2bg/marionette/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/sb2bg/marionette/actions/workflows/ci.yml)

Deterministic simulation testing for Zig.

Marionette helps Zig services reproduce timing, randomness, and simulated
failure from a seed.

Make rare bugs repeat themselves.

## What It Finds

The README example is a tiny retry queue. A worker leases a
job, times out, and the job is leased again. The bug is accepting the late
completion from the first worker after the second worker owns the lease.

Marionette turns that unlucky ordering into a replayable failure:

```text
marionette failure: kind=check_failed seed=12648430 profile=retry-queue-late-ack-bug ... error=JobCompletedTwice check=job completed at most once
```

The trace excerpt shows the race directly:

```text
queue.lease job=7 worker=1 deadline_ns=5000000
queue.timeout job=7 worker=1
queue.lease job=7 worker=2
queue.complete job=7 worker=1 accepted=true reason=stale_ack_bug completions=1
queue.complete job=7 worker=2 accepted=true reason=current_lease completions=2
queue.invariant_violation job=7 completions=2
```

The full example lives in
[`examples/retry_queue.zig`](examples/retry_queue.zig).

## Status

Phase 0. Time, seeded randomness, trace logging, replay checks, and named
world/state scenario checks are being built now. `ProductionEnv` and
`SimulationEnv` move authority selection to the composition root. Run tags and
typed attributes are trace-visible so failing seeds can carry their expanded
profile. An unstable deterministic network sketch exists for examples, but the
stable network API is still being designed. Disk, a real scheduler, shrinking,
and time-travel debugging are planned, not implemented.

The API is not stable. Do not use this in production yet.

## Try It

```sh
zig build test
zig build run-example -- replicated-register --seed 12648430 --summary
zig build run-example -- retry-queue-bug --seed 12648430 --expect-failure
```

## Why

Distributed systems bugs are hard because they depend on timing, ordering,
and failure. Traditional tests often find them by accident, if at all.

Deterministic simulation testing changes the loop: run the system in a
controlled world, save the seed and trace when it fails, replay the exact
execution until the bug is fixed.

Marionette is the Zig-native version of that idea: explicit interfaces,
explicit allocators, no runtime magic.

## Docs

- [Overview](docs/overview.md)
- [Architecture](docs/architecture.md)
- [Trace Format](docs/trace-format.md)
- [Run](docs/run.md)
- [BUGGIFY](docs/buggify.md)
- [Network Model](docs/network.md)
- [Network API Direction](docs/network-api.md)
- [Disk Fault Model](docs/disk-fault-model.md)
- [API](docs/api.md)
- [Determinism](docs/determinism.md)
- [Examples](docs/examples.md)
- [Roadmap](docs/roadmap.md)
- [Prior art](docs/prior-art.md)
- [TigerBeetle Lessons](docs/tigerbeetle-lessons.md)
- [Blog](docs/blog/index.md)

Current examples include a retry queue with a duplicate-completion bug, a rate
limiter, and a small replicated-register showcase that exercises seeded message
drops, deterministic delivery, and state checks.

## Is This For Me?

Eventually, yes, if you are building a database, queue, storage engine,
consensus system, scheduler, replicated service, or anything where
correctness under failure matters more than feature velocity.

Probably not, if you are building a CRUD app, GUI, ML training system, or a
multi-threaded service you are not willing to structure around deterministic
interfaces.

## Installation

Not published yet. Phase 0 is source-only while the core API settles.

## License

MIT. See [LICENSE](LICENSE).
