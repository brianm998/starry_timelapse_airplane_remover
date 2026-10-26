#!/usr/bin/env bash
# Phase 4 measurement for the removal checks: runs the built `star` and `star-removal-verify` over every
# (dataset x clean method) and collects the reports. Never fails the build on a measurement; it fails only when
# something could not run at all. Usage: gherkin/measure-removal.sh <os-label> <out-dir>
#
# Needs: cli built (cli/.build/release/star), trail_tools built (trail_tools/.build/release/star-removal-verify),
# test data fetched (test_data/fetch.sh a7sii_10 a7sii_10_crop16).
set -uo pipefail
os="${1:?os label}"; out="$(mkdir -p "$2" && cd "$2" && pwd)"
repo="$(cd "$(dirname "$0")/.." && pwd)"
star="$repo/cli/.build/release/star"
verify="$repo/trail_tools/.build/release/star-removal-verify"
cache="${STAR_TEST_DATA:-$repo/.test-data}"
[ -x "$star" ] && [ -x "$verify" ] || { echo "star or star-removal-verify is not built" >&2; exit 2; }

failed=0
# dataset:method[:extra verifier flags]; the unchanged-outside check is only valid for selective + lossless input.
runs=(
  "a7sii_10:selective"
  "a7sii_10:automatic:false"
  "a7sii_10:automatic:true"
  "a7sii_10_16bit:selective:--unchanged-outside"
  "a7sii_10_16bit:selective:--unchanged-outside:repeat"
  "a7sii_10_16bit:automatic:false"
  "a7sii_10_16bit:automatic:true"
)
# a7sii_10_crop16 is sky only, so it is run with --no-horizon (BUGS.md BUG-007: with the default horizon detection the detector invents a horizon there); only with MEASURE_CROP=1.
if [ "${MEASURE_CROP:-}" = "1" ]; then
  runs+=("a7sii_10_crop16:selective:--unchanged-outside" "a7sii_10_crop16:automatic:false" "a7sii_10_crop16:automatic:true")
fi
# "repeat" is an identical second run on the same runner: how much do two runs of the same thing differ? 
# On macOS also repeat one run with the GPU off, to see how far Metal and the CPU path differ on the same runner.
if [ "$os" = "macos" ]; then runs+=("a7sii_10_16bit:selective:--unchanged-outside:cpu"); fi

for spec in "${runs[@]}"; do
  IFS=: read -r ds m1 m2 m3 m4 <<< "$spec"
  case "$m1" in
    selective) method=selective; extra="${m2:-}"; tag="${m3:-}";;
    automatic) method="automatic:$m2"; extra="${m3:-}"; tag="${m4:-}";;
  esac
  name="$os-$ds-${method//:/_}${tag:+-$tag}"
  # MEASURE_FILTER=<substring> runs only matching runs (local smoke tests)
  [ -n "${MEASURE_FILTER:-}" ] && [[ "$name" != *"$MEASURE_FILTER"* ]] && continue
  work="$(mktemp -d)"; run="$out/$name"; mkdir -p "$run"
  echo "=== $name"
  mkdir "$work/seq"; cp "$cache/$ds"/*.jp*g "$cache/$ds"/*.tif "$work/seq/" 2>/dev/null
  flags=()
  [ "$tag" = "cpu" ] && flags+=(--no-use-gpu --no-use-gpu-for-sift --no-use-gpu-for-akaze)
  [ "$ds" = "a7sii_10_crop16" ] && flags+=(--no-horizon)   # sky only: BUG-007
  start=$(date +%s)
  "$star" -l info -c "$method" ${flags[@]+"${flags[@]}"} -o "$work/out" "$work/seq" > "$run/star.log" 2>&1
  rc=$?
  echo "star exit $rc after $(( $(date +%s) - start )) s" | tee "$run/star.status"
  grep -aE "GPU acceleration|Metal|OpenCL" "$run/star.log" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | sort -u > "$run/gpu.txt"
  outdir="$(ls -d "$work"/out/*star-v-* 2>/dev/null | head -1)"
  if [ "$rc" -ne 0 ] || [ -z "$outdir" ]; then echo "star failed: $name" >&2; failed=1; rm -rf "$work"; continue; fi
  "$verify" --input "$cache/$ds" --output "$outdir" --labels "$cache/$ds/labels.json" \
    --expect "airplane=removed,satellite=removed" --stars $extra --clean-method "$method" --dataset "$ds" \
    --report "$run/report.json" --crops "$run/crops" --report-only > "$run/verify.txt" 2>&1 || { echo "verifier failed: $name" >&2; failed=1; }
  rm -rf "$work"
done
exit $failed
