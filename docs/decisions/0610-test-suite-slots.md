# 0610: two test-suite slots

Task #597. With `test-suite` at 1, concurrent tasks serialised on it (27% of task time waiting). Chosen: count 2, the smallest change.
Rejected for now: running only changed-package suites (the impact map already does this) and splitting suites by cost (needs measured
runtimes; most min_tests are still UNMEASURED). Timing, QoS and memory suites stay `exclusive`. Risk: two heavy suites at once (e.g.
StarCore with 8 workers beside desktop gradle) raise memory pressure; if the machine swaps, go back to 1 and split by cost instead.
The owner's resources.toml overrides this file's count.
