# Marionette

Deterministic simulation testing for Zig.

Marionette helps Zig services reproduce timing, randomness, and eventually
disk/network failures from a seed.

Same seed. Same trace. Same bug.

```zig
const std = @import("std");
const mar = @import("marionette");

test "scenario is replayable" {
    const ns_per_ms: mar.Duration = 1_000_000;
    var world = try mar.World.init(std.testing.allocator, .{
        .seed = 0xC0FFEE,
        .tick_ns = ns_per_ms,
    });
    defer world.deinit();

    try world.tick();
    _ = try world.randomU64();
    try world.record("request.accepted id={}", .{42});

    try std.testing.expectEqualStrings(
        \\marionette.trace format=text version=0
        \\event=0 world.init seed=12648430 start_ns=0 tick_ns=1000000
        \\event=1 world.tick now_ns=1000000
        \\event=2 world.random_u64 value=10121301305976376037
        \\event=3 request.accepted id=42
        \\
    , world.traceBytes());
}
```

## Status

Phase 0. Time, seeded randomness, and trace logging are being built now.
Disk, network, scheduling, shrinking, and time-travel debugging are planned,
not implemented.

The API is not stable. Do not use this in production yet.

## Try It

```sh
zig build test
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
- [API](docs/api.md)
- [Determinism](docs/determinism.md)
- [Examples](docs/examples.md)
- [Roadmap](docs/roadmap.md)
- [Prior art](docs/prior-art.md)

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

TBD. Expected to be MIT or Apache-2.0 before a Phase 0 release.
