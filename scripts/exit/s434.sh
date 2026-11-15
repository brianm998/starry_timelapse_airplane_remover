#!/bin/bash
set -e
cd "$(dirname "$0")/../../pipeline"
STAR_USE_GPU_FOR_MERGE=0 timeout 120 uv run pytest -q -o faulthandler_timeout=60 tests/test_daemon.py::test_schedule_once_claims_one_ticket_and_runs_it
echo "s434 OK"
