# 0667: the smoke (macos-15) job prints its evidence last

Task #664. `Gherkin smoke / smoke (macos-15)` stayed red on develop, and the log tail the watch shows
is only artifact uploads ("no files were found"), so the cause was invisible. Decision 0652 assumed
the Icon Composer actool failure; that was never confirmed for this job.

Decision: the smoke job gets the same last-step `Failure evidence` as the shard mac gui job: leg
outcomes, `error:`/actool lines, cli and gui log tails, xcresult summary, runner container tmp.

Root cause: not yet identified. It must be read from the next red smoke run's evidence step. If it
differs from 0652's assumption, 0652's status is wrong; if the blocker is not the icon, file it as a
new task with the captured error. No guess at a code fix is made here.
