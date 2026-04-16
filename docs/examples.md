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

## Example Rules

- Keep examples focused and readable.
- Prefer one clear service behavior over a broad feature tour.
- Route time and randomness through Marionette interfaces.
- Return or expose traces so tests can compare replay behavior.
- Avoid `std.time`, unseeded randomness, threads, filesystem, and network
  calls in simulated example code.
