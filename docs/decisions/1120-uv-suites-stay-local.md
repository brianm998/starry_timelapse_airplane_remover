# 1120: #1163 is covered by decision 1125

## Evidence

Task #1152's test step: `(t0-pipeline-static: ran on node marmot (arm64), 0 s) ... sh: uv: command not found`
(status 127). This is the same failure #1159 reported.

## Decision

Nothing further to change. #1159 landed first with `remote = false` on `t0-pipeline-static` and `test-pipeline`
and `pipeline/tests/test_mason_toml_uv.py` guarding it; #1163 had made the same change on its own branch, and
the merge keeps the landed version of both files. The reasons, and how to undo it, are in
`docs/decisions/1125-uv-suites-stay-local.md`.
