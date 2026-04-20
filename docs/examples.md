# Examples

Examples are small enough to read quickly, but they exercise the real
Marionette APIs. Each example should become useful input for deterministic
replay tests.

## Rate Limiter

Source: [`examples/rate_limiter.zig`](../examples/rate_limiter.zig)

The examples module root is [`examples/root.zig`](../examples/root.zig).
Add new examples there so `zig build test` picks them up without hard-coding
each example in `build.zig`.

The rate limiter is a token bucket with jittered refill scheduling. It uses:

- `Clock.now()` to decide when refills are due.
- `World.randomIntLessThan(...)` to jitter the next refill time without modulo
  bias and with trace visibility.
- `World.record(...)` to produce a replayable trace.
- `mar.run(...)` to execute the scenario twice and compare traces.

Run it with the rest of the test suite:

```sh
zig build test
```

The useful entry point for later determinism tests is:

```zig
const trace = try rate_limiter.runScenario(allocator, 0xC0FFEE);
defer allocator.free(trace);
```

`runScenario` delegates to `mar.run`, so every call already performs
twice-and-compare replay. Calling it with different seeds may produce different
traces because the refill schedule is jittered from the seeded random stream.

## Replicated Register

Source: [`examples/replicated_register.zig`](../examples/replicated_register.zig)

The replicated register is the first VOPR-inspired showcase. It is not a real
consensus protocol and does not copy TigerBeetle internals. It demonstrates the
portable shapes Marionette needs:

- A small cluster model with three replicas.
- Seeded message drops and delivery latency.
- A deterministic pending-message order of `(deliver_at, message_id)`.
- Trace events for sends, drops, deliveries, accepts, commits, and checks.
- A named `mar.Check` that fails when the trace records committed divergence.

The normal scenario writes one value to a quorum and commits it:

```zig
const trace = try replicated_register.runScenario(allocator, 0xC0FFEE);
defer allocator.free(trace);
```

The example also includes a deliberately buggy scenario used by tests to prove
the checker path catches divergent committed state:

```zig
var report = try replicated_register.runBuggyScenario(allocator, 0xC0FFEE);
defer report.deinit();
```

This is intentionally tiny. Its job is to make the future scheduler, network,
and invariant APIs concrete enough to critique before they become core library
surface.

## Example Rules

- Keep examples focused and readable.
- Prefer one clear service behavior over a broad feature tour.
- Route time and randomness through Marionette interfaces.
- Return or expose traces so tests can compare replay behavior.
- Avoid `std.time`, unseeded randomness, threads, filesystem, and network
  calls in simulated example code.
