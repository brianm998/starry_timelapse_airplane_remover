# 0612: known-unmeasurable suites, no rule added yet

Task #599. Interventions run about 1.5 per landed task, mostly retry and skip_test. Decision 0606 traced a
share of them to the nine `min_tests = 1 # UNMEASURED` suites in `.mason/mason.toml` (test-logging, test-monitor,
test-StarCpp-qos, test-cli, test-trail_tools, test-decision_tree_generator, test-gherkin, test-gui, test-desktop,
test-pipeline), whose count cannot prove a run.

Tried: running pytest in `pipeline/` (one test failed, so that run cannot give a count either) and
`swift test` for logging, trail_tools, decision_tree_generator and pipeline/monitor through `mason run`. The swift
runs sat in masond's queue past the 10 minute limit of this session, so no count was read.

Decided: no config change is made on a guess. A wrong `min_tests` turns a green suite red, which costs more
interventions, not fewer. The rule MASON needs (a suite flagged unmeasured is accepted on its parser's own pass
verdict, and its first green run records the count) is a MASON change, not a star one.
Next step: read the counts from the first green shadow run of each suite and replace the `1`.
