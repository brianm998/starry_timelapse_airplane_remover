#!/usr/bin/env bash
# Resolve a SwiftPM package's dependencies, retrying with backoff: github.com
# sometimes answers 403 for a while on shared runners.
set -u
path="${1:?usage: swift-resolve-retry.sh <package-path>}"
delays=(15 30 60 90)
for attempt in 1 2 3 4 5; do
  if swift package resolve --package-path "$path"; then exit 0; fi
  if [ "$attempt" -eq 5 ]; then break; fi
  d="${delays[$((attempt-1))]}"
  echo "::warning::swift package resolve failed for $path (attempt $attempt of 5); retrying in ${d}s"
  sleep "$d"
done
exit 1
