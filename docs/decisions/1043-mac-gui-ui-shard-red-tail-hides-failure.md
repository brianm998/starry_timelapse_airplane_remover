# 1043: mac gui ui shard red, and its log tail hides the failure

Run 45245649442 (`Gherkin/mac gui (macos-15) · ui`) is red. The tail the watch captured is only
`== <feature>: passed` lines and `exit code 1`: `prove-xctest-features.sh` printed each failing
feature's `::error::` and evidence block inside its loop, before the later passed features, so the
tail never showed them. The failing feature could not be read offline (as in decisions 0511 and
0601 and stage s1047). The likely suspect is uiUpdateSettingsMidRun (it failed on run 45036982757),
but that is unproven and no fix was guessed.

Decision: the script now prints the passed lines first, then all failure output, and ends with
`FAILED: <feature (result), ...>`. Exit codes, annotations and the step summary are unchanged. CI
tooling only: no localization and no Kotlin change.

Next step: read run 45245649442's `Prove the scenarios ran` output and the
`gherkin-gui-shard-ui-xcresult` artifact, then fix the named feature.
