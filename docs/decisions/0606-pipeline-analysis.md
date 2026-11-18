# 0606: pipeline analysis findings

Task #596. Analysis only; no code changed. Five findings, written to `analyst-result.json` (not committed):
wait_share (test-suite count = 1, .mason/mason.toml:121), repeat_failure_rate (test reds, 1.02 per landed task),
interventions_per_landed (retry/skip_test overrides), landing_idle_ms (340h in landing, .mason/landing.toml),
and the 12 `min_tests = 1 # UNMEASURED` suites whose pre-#253 definitions cause repeated debts (#253, #198, #199).
The draft's cited lines were re-pointed to the real lines of mason.toml (476 lines). Recommendation: measure the
UNMEASURED counts first (small cost, removes the recurring approvals).
