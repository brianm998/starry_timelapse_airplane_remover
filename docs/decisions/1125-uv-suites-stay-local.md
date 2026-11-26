# 1125 — star's uv suites stay on this Mac

## Problem
MASON placed `t0-pipeline-static` on node marmot, which has no `uv`: `sh: uv: command not found`, exit 127
(task #1131, run 6765). The same suite passed on this Mac the same day. MASON counted the missing tool as a red test.

## Decision
`remote = false` on `[suite.t0-pipeline-static]` and `[suite.test-pipeline]` in `.mason/mason.toml`, the two suites
that run `uv`. MASON then keeps them local even with no `[remote_runs]` section in star's file.
`pipeline/tests/test_mason_toml_uv.py` fails if a suite that runs `uv` lacks the key.

Installing `uv` on marmot was the other choice. It is setup of another machine, which belongs to the owner and which
this repository cannot do.

## Undoing it
Once every node has `uv` on the node daemon's PATH (for example in `/opt/homebrew/bin`), remove the two keys and
the test.

## Not covered
Other things a node may lack, not verified on marmot: OpenCV, the Android Studio `JAVA_HOME` of `t0-proto-sync`,
and the signing identity of `build-gui`. MASON judging exit 127 as a red test, not an environment failure, is
MASON's to change.
