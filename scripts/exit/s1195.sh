#!/usr/bin/env bash
# s1195 exit check for task #1171: qos floor is 2 and the floor policy is documented.
set -euo pipefail
grep -A3 'suite.test-StarCpp-qos' .mason/mason.toml | grep -q . 
grep -q 'min_tests = 2 # one test skips on x86_64' .mason/mason.toml
grep -q 'min_tests policy (#1171)' .mason/mason.toml
echo ok
