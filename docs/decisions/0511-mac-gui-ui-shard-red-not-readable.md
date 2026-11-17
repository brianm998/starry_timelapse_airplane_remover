# 0511: mac gui ui shard red; failure not readable

Task #510. `Gherkin: full/mac gui (macos-15) · ui` was red at bd17822 (run 43912477865, same run as 0497). The task's log tail holds
only post-job artifact uploads and the session had no network, so the failure was **not read**. No fix was guessed.

Instead the next red run explains itself: `gherkin/prove-xctest-features.sh` prints each failed feature's XCTest failure lines (or the
log tail and crash markers when no test started) into the log, annotation and step summary, and an `if: failure()` step prints the
xcresult summary. No feature was skipped and no timeout changed.

Next step: read the `gherkin-gui-shard-ui-xcresult` and `-artifacts` artifacts of that run, or the next red log, and fix the cause.
