# 0601: mac gui ui shard red again; cause still not read

Task #593. `Gherkin: full/mac gui (macos-15) · ui` is red at 7d75f0fb (run 44345980413). The task's log tail holds only post-job
artifact uploads, and this session had no network, so the cause was **not read**. No fix was guessed (same as 0511).

The "No files were found" warnings for the `gherkin-artifacts` and `gallery` paths are non-fatal and are not the cause.

The failure instrumentation from 0511 exists (`gherkin/prove-xctest-features.sh` failure evidence, `if: failure()` xcresult summary).
No feature was skipped and no timeout changed.

Next step: from run 44345980413 read the `Prove the scenarios ran` step output, the xcresult summary step, and the
`gherkin-gui-shard-ui-xcresult` artifact (Artifact ID 14454767527), then fix the cause in a follow-up.
