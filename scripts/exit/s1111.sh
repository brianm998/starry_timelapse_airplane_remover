#!/usr/bin/env bash
# s1111 exit check for task #1131: the stopped-run alert's catalogue keys. Static only (no build, no GPU use); the
# behaviour is covered by RunMarkerTests, WarningAlertTests and CriticalWarningDialogTest.
set -euo pipefail
cd "$(dirname "$0")/../.."
dir=StarCore/Sources/StarCore/Resources/Localizations
count=0
for f in "$dir"/*.json; do
  [ "$(basename "$f")" = languages.json ] && continue
  grep -q '"run_marker.brief.not_restartable"' "$f" || { echo "FAIL: $f lacks run_marker.brief.not_restartable"; exit 1; }
  ! grep -q '"run_marker.brief.resume"' "$f" || { echo "FAIL: $f still has run_marker.brief.resume"; exit 1; }
  count=$((count + 1))
done
[ "$count" -eq 22 ] || { echo "FAIL: expected 22 catalogues, found $count"; exit 1; }
! grep -rq 'run_marker\.brief\.resume' StarCore/Sources || { echo "FAIL: the removed key is still referenced"; exit 1; }
python3 i18n/check.py >/dev/null
echo "s1111 OK"
