# API Reference

Import the package as:

```zig
const mar = @import("marionette");
```

Marionette is pre-1.0. The root exports are the supported surface, but they may
still change between minor releases.

## Simulation Runner

`runSimCase` is the primary runner. It creates a world, constructs the
simulation, initializes application state, runs the scenario and named checks,
then repeats the execution with the same seed and compares traces.

```zig
const Case = mar.SimCase(App);

fn init(sim: mar.Sim) !App {
    return App.init(sim.env.io(), sim.env.recorder());
}

fn scenario(case: *Case) !void {
    try case.app.work();
    try case.control().tick();
}

fn invariant(case: *const Case) !void {
    if (!case.app.valid()) return error.InvalidState;
}

const checks = [_]mar.StateCheck(Case){
    .{ .name = "application state is valid", .check = invariant },
};

test "scenario" {
    try mar.expectSimPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .simulate = mar.World.SimulateOptions{},
        .init = init,
        .scenario = scenario,
        .checks = &checks,
    });
}
```

Required runner fields are `allocator`, `simulate`, `init`, and `scenario`.
`simulate` must be a `mar.World.SimulateOptions` value. Optional fields are
`seed`, `start_ns`, `tick_ns`, `name`, `tags`, `attributes`, `checks`, and
`watchdog`.

- `runSimCase` returns an owned `RunReport`.
- `expectSimPass` accepts only a passing replay.
- `expectSimFailure` accepts a replayable failure; an optional `failure =
  FailureExpectation{ ... }` constrains its kind, error name, and/or check
  name.
- `expectSimFuzz` repeats a case across a derived seed sequence; add `seeds`.
- `expectTraceContains` prints the trace tail when an expected event is absent.

Call `RunReport.deinit`. A passed report contains the first trace and event
count. A failed report contains its failure kind, error/check names, partial
first trace, and a second trace when replay diverged.

`RunFailureKind` includes scenario and check errors, structured scheduler
deadlocks/errors, watchdog-classified `non_yielding`/`livelock` failures, and
the three replay-mismatch outcomes.

`WatchdogOptions` enables optional worker-process containment with
`stall_timeout_ns`, `run_timeout_ns`, and `trace_capacity` bounds. It is
available on Linux, macOS, the supported BSD hosts, and illumos. The watchdog
uses host monotonic time outside simulation and should be enabled only from a
single-threaded harness process. Unsupported hosts return
`error.WatchdogUnavailable`; invalid or unrepresentable bounds return
`error.InvalidWatchdogOptions`. `error.WatchdogTraceTooLarge` indicates that
failure identity metadata could not fit the worker result channel.

## Scenario State

`SimCase(App)` contains:

- `sim`: the `World.Simulation` returned by `World.simulate`;
- `app`: state returned by the configured initializer;
- `env()`: the node-zero application environment;
- `control()`: harness-only fault and scheduling controls.

If `App` defines `deinit`, the runner calls it after every replay.

`StateCheck(State)` contains a stable name and a function taking
`*const State`. Check errors become `check_failed` reports.

## Application Capabilities

`Env` supplies the remaining Marionette-aware capabilities:

- `io()` returns deterministic `std.Io` in simulation or caller-provided host
  I/O in production;
- `allocator()` returns the configured application allocator;
- `recorder()` returns a narrow `Recorder`;
- `record` writes one structured trace event;
- `buggify` evaluates a named simulation-only fault hook.

`Recorder.none()` drops events. Simulation environments return a recorder
backed by the world's trace. Production-shaped libraries should usually accept
`std.Io`, `std.Io.Dir`, and `Recorder` rather than all of `Env`.

`Production.init` combines caller-owned host I/O, a root directory, an
allocator, and an optional recorder into an `Env`. Call `deinit` when finished.

## World And Simulation

`World.init(allocator, options)` owns seeded randomness, virtual time, trace
bytes, and simulator resources. Call `deinit`.

`World.simulate(options)` is one-shot and returns `Sim`:

- `sim.env` is the node-zero application environment;
- `sim.control` is the harness authority;
- `sim.envForNode(node)` returns process-scoped I/O;
- `sim.endpoint(Payload, node)` opens an experimental typed endpoint;
- process registration, kill, restart, and liveness transition helpers live on
  the simulation value.

`World.SimulateOptions` configures allocation faults, disk geometry/latency,
optional network topology, task stacks, start jitter, and fiber overflow
diagnostics.

## Control

`Control` contains:

- `allocation`: fault configuration and address-free statistics;
- `disk`: crash/restart and disk-fault controls;
- `network`: loss, latency, clogs, partitions, link and node state;
- `process`: process crash/restart dynamics;
- `tasks`: cooperative scheduler inspection;
- `tick`, `runFor`, and `runTasksUntilIdle` for virtual-time execution.

Harness authority must not be stored in production application state.

## Profiles And Metadata

`SimProfile` expands named workload profiles into simulate options, tags, and
typed replay attributes. `runAttribute(key, value)` accepts strings, integers,
booleans, and floats.

## Traces And Summaries

`World.record` and `Env.record` append line-oriented events. Dynamic text must
be passed through structured fields or encoded so spaces and control bytes do
not invalidate the trace grammar. See [Trace Format](trace-format.md).

`summarize(allocator, trace)` builds an owned `Summary` with event, subsystem,
run metadata, and network counts. Call `Summary.deinit`.

## Seed Parsing

`parseSeed` accepts a decimal `u64` or a 40-character Git hash. Hashes map to
the first eight raw digest bytes in big-endian order.

## Build Tidy

The build API exports `addTidyStep` and `addTidyExecutable`. The AST-based scan
rejects configured ambient host authorities while ignoring comments and string
literals. Prefer narrow pattern allowlists to whole-file exemptions.
