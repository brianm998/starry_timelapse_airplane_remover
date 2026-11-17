# 0497: Windows ui shard still red after 0493; failure not readable

Task #490. The Windows ui leg stayed red at bd17822 after the sharing-violation retries of decision 0493.
The task's log tail holds only the post-job artifact upload, and the session that made this change had no network, so the
failing step was **not read**. Guessing a third fix would repeat the mistake of 0493.

Instead the next red run explains itself: `run-desktop-features.sh` prints each failed feature's name and the first
`<failure>`/`<error>` message of its Gradle XML into the job log (and a `$GITHUB_STEP_SUMMARY` line), and
`summarize-desktop-features.sh` does the same. No skip, timeout or check was changed.

Next step: read run 43912477865's `gherkin-desktop-windows-reports-shard-ui` artifact (`gherkin-each/*.xml`,
`hang-watchdog.log`) and fix the cause.
