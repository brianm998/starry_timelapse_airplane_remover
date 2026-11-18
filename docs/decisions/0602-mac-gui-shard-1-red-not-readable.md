# 0602: mac gui shard 1 red; failure not readable

Task #594. `Gherkin: full/mac gui (macos-15) · shard 1` (autoHorizonJpegVideoOut, autoHorizonJpeg, autoSelectiveHorizonTiff16,
selectiveHorizonTiff16) was red at 7d75f0fb (run 44345980413). The session had no network, so the xcresult and the `Prove the scenarios
ran` output were not read. Guessing a fix would be worse than none, and prove-xctest-features.sh is not weakened.

Next step: read the `gherkin-gui-shard-1-xcresult` artifact or the failed step's log (decision 0511 already makes it print the XCTest
failures and the xcresult summary), classify it (assertion, crash/OOM, timeout, hang), and fix the cause.
