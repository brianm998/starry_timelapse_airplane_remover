# 1185 — test-count floors come from executed counts

Floors set at ~90% of a static count of test functions failed healthy runs (qos needed 3, 2 ran; test-cli needed 80 of 78).
Decision: a `min_tests` floor is set from what a base run executed (skips excluded) and re-measured when the suite changes.
test-StarCpp-qos is now 2. The policy is written above `[suite.test-logging]` in `.mason/mason.toml`.
