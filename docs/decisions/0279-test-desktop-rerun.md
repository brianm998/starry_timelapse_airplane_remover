# 0279: test-desktop uses `test --rerun`

`--rerun` (Gradle 7.6+; the wrapper is 8.11) binds to the `test` task and forces it to execute without rerunning compile tasks.
Deleting `build/test-results/test` first was rejected: Gradle would still see :test as UP-TO-DATE and write no XML.
