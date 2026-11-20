# 0673: desktop (ubuntu-24.04) failure evidence

Task #670 is the third red of Gherkin desktop (ubuntu-24.04) shard 1. Its log tail shows only upload and cleanup lines, so the cause is still unread.

The old "Name the failed step" step could not show it, for two reasons. It ran before the two upload steps, so its output was not in the tail the watch captures. Its `gh api` call needs `actions: read`, which neither gherkin.yml (`contents: read`) nor its callers (`contents: write`) granted, and `|| true` hid the error.

The step is now last, renamed "Failure evidence (last, so the log tail shows it)". It warns when the API call fails and prints `df -h` and the tails of the gherkin-each logs. desktop-linux and every caller of gherkin.yml (gherkin-smoke.yml twice, macos-gate.yml) grant `actions: read`. The underlying failure is not guessed at: the next red will name the failed step.
