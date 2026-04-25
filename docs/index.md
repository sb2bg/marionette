# Marionette

Deterministic simulation testing for Zig.

Marionette helps Zig services reproduce timing, randomness, and simulated
failure from a seed.

Make rare bugs repeat themselves.

## Status

Marionette is experimental. Time, seeded randomness, trace logging, replay
checks, named scenario checks, trace summaries, trace-visible run context, and
a deterministic disk authority with replayable faults and crash/restart
simulation are implemented. An unstable deterministic network sketch exists
for examples.

A real scheduler, shrinking, and time-travel debugging are planned, not
implemented. The API is not stable, and Marionette is not ready for production
use.

## Start Here

- [Overview](overview.md)
- [Determinism](determinism.md)
- [Run](run.md)
- [Network Model](network.md)
- [Network API Direction](network-api.md)
- [API](api.md)
- [Roadmap](roadmap.md)

## Blog

- [Why deterministic replay in Zig is harder than it sounds](blog/why-deterministic-replay-in-zig-is-harder-than-it-sounds.md)

## Try It

```sh
zig build test
```
