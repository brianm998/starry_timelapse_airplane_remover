# 1120: the uv suites stay on this Mac

## Evidence

Task #1152's test step: `(t0-pipeline-static: ran on node marmot (arm64), 0 s) ... sh: uv: command not found`
(status 127). Both `t0-pipeline-static` and `test-pipeline` call `uv` by name, and the same command passes on this
Mac (`/usr/local/bin/uv`). Any change touching `pipeline/**`, `scripts/**` or `.mason/**` went red for an
environment reason.

## Options

1. Install uv on marmot in a directory on the node's job PATH (`/usr/local/bin` or `/opt/homebrew/bin`).
2. Set `remote = false` on both suites in `.mason/mason.toml`.

## Decision

Option 2. It lives in the repository, is reviewable, and is guarded by
`pipeline/tests/test_mason_toml_uv.py`. Installing uv is a change to another machine that nothing here records
or checks.

## Cost

These two suites cannot spill to another machine; they wait for this Mac.

## Reverting

Install uv in `/usr/local/bin` or `/opt/homebrew/bin` on every node, then drop the two `remote = false` lines and
relax or delete the test.
