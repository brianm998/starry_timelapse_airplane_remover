# 0608: desktop smoke shard 1 red; failure not readable

Task #611. `Gherkin smoke/smoke / desktop (ubuntu-24.04) · shard 1: autoHorizonJpeg` was red at 633b7b1c (run 44403809350). The ticket's
log tail is post-job cleanup only. Its evidence is `No files were found ... star-desktop/build/gherkin-each`: gherkin.yml says that
directory is missing when a step before `gherkin/run-desktop-features.sh` failed (fetch, apt, Swift, build, stard), so the run script
never started. The session had no network, so the failed step was not read. No fix was guessed, and the prove/guard steps are not weakened.

Next step: open the first failed step of `desktop (ubuntu-24.04) · shard 1` in run 44403809350, classify it (apt/network, Swift or stard
build, ffmpeg fetch, runner problem) and fix it, with a regression guard if it is a workflow defect.
