#!/bin/bash
# Run one StarCore test (default: the #108/#130 concurrent-mask stress test) in a release build under AddressSanitizer.
# Usage: tools/heap-hunt/asan-xctest.sh [Class/testName]
# See README.md. All builds and runs go through `starpipe heavy`, one at a time.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$REPO/StarCore"
"$STARPIPE" heavy -- swift build -c release --build-tests --sanitize=address -Xswiftc -enable-testing

# The toolchain's ASan runtime, ad-hoc re-signed into the scratch dir (the copy inside the Xcode bundle is rejected
# with 'Sanitizer load violates platform policy').
RT="$(dirname "$(xcrun -f clang)")/../lib/clang"
RT="$(find "$RT" -name libclang_rt.asan_osx_dynamic.dylib | head -1)"
[ -n "$RT" ] || { echo "no libclang_rt.asan_osx_dynamic.dylib found" >&2; exit 1; }
cp "$RT" "$SCRATCH/libclang_rt.asan_osx_dynamic.dylib"
codesign -f -s - "$SCRATCH/libclang_rt.asan_osx_dynamic.dylib"

write_wrapper "$SCRATCH/asan-wrapper.sh" \
  "DYLD_INSERT_LIBRARIES=$SCRATCH/libclang_rt.asan_osx_dynamic.dylib" \
  "MallocNanoZone=0" \
  "ASAN_OPTIONS=${ASAN_OPTIONS:-detect_stack_use_after_return=1:abort_on_error=0}"

BUNDLE="$(find "$REPO/StarCore/.build" -path '*release*' -name '*.xctest' -maxdepth 4 | head -1)"
[ -n "$BUNDLE" ] || { echo "no release .xctest bundle under StarCore/.build" >&2; exit 1; }
"$STARPIPE" heavy -- "$SCRATCH/asan-wrapper.sh" "$XCTEST" -XCTest "$TEST" "$BUNDLE"
