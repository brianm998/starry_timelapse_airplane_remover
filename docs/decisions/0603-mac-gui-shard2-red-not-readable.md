# 0603: mac gui shard 2 red; failure not readable

Task #595. `Gherkin: full/mac gui (macos-15) · shard 2` (autoHorizonVideo, autoHorizonTiff16, autoSkyOnlyTiff16) was red at 7d75f0fb
(run 44345980413). The task's log tail holds only post-job artifact uploads and the session had no network, so the cause was **not read**.
No fix was guessed. The tail does show that the `gherkin-artifacts` and `gallery` folders were empty: no feature of the shard got as far as
writing validator output. Same situation as 0511.

The prove and xcresult-summary steps now save their output under `$RUNNER_TEMP`, and a last `if: failure()` step ("Failure evidence")
re-prints it, the log tail and the crash markers after the uploads, so the next red run's log tail states its cause.

Artifacts to open: `gherkin-gui-shard-2-xcresult` of run 44345980413. Hypotheses to check against them: the app crashing or being
jetsammed on a 7 GB hosted VM while processing 16-bit TIFF or decoded video frames; the ffmpeg artifact; the sandbox container path.

Nothing was skipped and no timeout was changed. CI tooling only: no localization, no Kotlin twin.
