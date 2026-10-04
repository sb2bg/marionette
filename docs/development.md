# Local Verification

Use Zig 0.17.0 and run from a Git checkout:

```sh
tools/verify.sh fmt    # formatting and whitespace only
tools/verify.sh quick  # build, debug tests, tidy, downstream consumer
tools/verify.sh        # full native optimization and external validation matrix
```

Set `ZIG=/path/to/zig` to select a toolchain. The full command runs debug,
safe, and fast tests plus all six pinned external validations,
then compiles the disabled Win64 fiber path and checks release symbols.
The ordinary test step includes tidy, the package consumer, supported host fiber
checks, and the bounded queue, network KV, and storage compatibility validations.
External validations may fetch their pinned lazy dependencies on the first run.
Ochi validation is unavailable until its upstream build and dependencies support
Zig 0.17; `zig build validate-ochi` reports this explicitly. Its harness is retained
in `validation/ochi_store.zig` and syntax-ported to Zig 0.17, but it is not compiled
until Ochi builds again (previous pin: `f8b2e9c804571e4d2203658589123e974feac4c2`).
Negative-run tests intentionally print failure summaries; check the build summary
and exit status to distinguish those from failing tests.

Formatting checks the `.zig` and `.zon` files Git tracks or would track, so
ignored dependencies and build caches are skipped. It works in a dirty checkout,
and CI runs the same command.

The native matrix only validates the current host. Linux and macOS CI jobs are
still release gates; a green local run is not evidence that another OS passed.
The [release checklist](releasing.md) also requires Pages and clean installation.

`tests/compatibility_072.zig` compares lifecycle and reduction traces, tapes,
capsules, and manifests byte for byte with fixtures captured from v0.7.1. Keep
pinned-build identity rejection tests enabled even when these bytes match.

For repeatable measurements before performance work, see
[Performance Baseline](performance.md).
