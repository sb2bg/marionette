# Findings

Marionette keeps a characterized findings ledger at
[`FOUND_BUGS.md`](https://github.com/sb2bg/marionette/blob/main/FOUND_BUGS.md).

That file records external-SUT results only after the failure is understood
well enough to distinguish:

- confirmed system-under-test bugs,
- simulator-boundary counterexamples,
- harness or model bugs,
- and positive robustness results.

The current ledger includes kvdb B+tree correctness findings and xitdb
torn-write boundary results. The distinction is deliberate: Marionette should
not turn every failing seed into an overclaimed upstream bug.
