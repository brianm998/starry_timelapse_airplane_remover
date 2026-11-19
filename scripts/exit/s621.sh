#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s621.md
! grep -q "min_tests = 1 # UNMEASURED" .mason/mason.toml
echo "s621 OK"
