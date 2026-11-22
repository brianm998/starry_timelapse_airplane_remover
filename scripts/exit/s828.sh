#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s828.md
[ -f docs/decisions/0821-client-parity-check.md ]
python3 i18n/client_parity.py
python3 i18n/tests/test_client_parity.py
python3 i18n/check.py >/dev/null
echo "s828 OK"
