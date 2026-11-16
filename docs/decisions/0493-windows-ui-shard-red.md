# 0493: Windows ui shard (uiPainterWaitsForExtraction)

The task's log tail held only the artifact upload, and this session had no network to read the run's artifacts, so the failing step was not
read from a log. The only feature the README names as red on Windows is `uiPainterWaitsForExtraction`, which uses the `<video>.hold` seam.
Windows-specific candidates there: `File.delete` of the hold while StarCore has it open, and `moveItem` of a staged frame while ffmpeg or
another handle holds it. Both now retry for a short bounded time (runner: 10 s; StarCore `moveWithRetry`: 40 x 50 ms). No skip, ignore,
timeout or continue-on-error was added; the "ran, not skipped" check is untouched. If the next Windows run is still red, its `STEP HUNG`
dump names the call.

No user-visible strings change: no localization edits, no gui/Kotlin twin (StarCore behaviour only on a failure path).
Unit test: `VideoFrameSourceTests.testMoveWithRetryMovesAndGivesUpOnAMissingSource`.
