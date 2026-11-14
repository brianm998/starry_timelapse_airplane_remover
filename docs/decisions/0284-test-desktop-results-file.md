# 0284: One merged results file for test-desktop

Status: accepted

Context: MASON reads `results_file` with `fs::read`, so the glob `test/*.xml` was never found ("was not written").

Decision: a Gradle `mergeTestResults` task, run by `finalizedBy` on `test` (so also after failures), concatenates the `TEST-*.xml` suites into `build/test-results/test-all.xml` under a `<testsuites>` root, and `results_file` names it. No MASON change, and no file named `*.xml`.
