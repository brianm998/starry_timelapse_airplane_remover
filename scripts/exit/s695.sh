#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s695.md
[ -f docs/decisions/0688-macos-installer-icon-fallback.md ]
! grep -q "if (onCi) throw" star-desktop/build.gradle.kts
cd star-desktop && pipeline_heavy=../pipeline/bin/starpipe && "$pipeline_heavy" heavy -- ./gradlew help compileKotlin
echo "s695 OK"
