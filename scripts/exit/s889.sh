#!/usr/bin/env bash
# Exit check for s889 (task #838): the closure exists and fires only for removed files.
set -euo pipefail
cd "$(dirname "$0")/../.."
grep -q imageDeletedClosure StarCore/Sources/StarCore/ImageAccessor.swift
grep -q imageDeletedClosure gui/star/ImageSequenceViewModel.swift
(cd StarCore && STAR_USE_GPU_FOR_MERGE=0 swift test --filter ImageAccessorDeletedClosureTests)
echo S889-OK
