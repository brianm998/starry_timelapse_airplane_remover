#!/bin/bash
# Replay a window of a real sequence through the cli, release build, under AddressSanitizer.
# Usage: tools/heap-hunt/replay-cli-asan.sh <input-dir> <first> <last>
#   <first>/<last> are 1-based positions in the sorted listing of <input-dir> (for LRT_00001.tiff.. they equal the
#   frame number). The frames are COPIED to the scratch dir (the input dir is only read), so the cli's star_temp_* and
#   output siblings land in .heap-hunt-scratch/ and the original run's state is never touched.
# Env: STAR_REPLAY_ARGS  cli flags before the input dir (default: --moving-camera --no-use-gpu; this Mac must run the
#      CPU median merge, see CLAUDE.md).
# See README.md. All builds and runs go through `starpipe heavy`, one at a time.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
IN="${1:?usage: replay-cli-asan.sh <input-dir> <first> <last>}"; FIRST="${2:?first}"; LAST="${3:?last}"
ARGS="${STAR_REPLAY_ARGS:---moving-camera --no-use-gpu}"

STAGE="$SCRATCH/replay-$FIRST-$LAST"
if [ ! -d "$STAGE" ]; then
  mkdir -p "$STAGE.partial"
  ls "$IN" | sort | sed -n "${FIRST},${LAST}p" | while read -r f; do cp "$IN/$f" "$STAGE.partial/$f"; done
  mv "$STAGE.partial" "$STAGE"
fi
echo "staged $(ls "$STAGE" | wc -l | tr -d ' ') frames in $STAGE"

cd "$REPO/cli"
"$STARPIPE" heavy -- swift build -c release --sanitize=address
STAR="$(swift build -c release --sanitize=address --show-bin-path)/star"

RT="$(dirname "$(xcrun -f clang)")/../lib/clang"
RT="$(find "$RT" -name libclang_rt.asan_osx_dynamic.dylib | head -1)"
[ -n "$RT" ] || { echo "no libclang_rt.asan_osx_dynamic.dylib found" >&2; exit 1; }
cp "$RT" "$SCRATCH/libclang_rt.asan_osx_dynamic.dylib"
codesign -f -s - "$SCRATCH/libclang_rt.asan_osx_dynamic.dylib"

# detect_container_overflow=0: the linker coalesces OpenCV's uninstrumented, annotation-free copy of
# std::vector<cv::Mat>::__insert_with_size over Star's, so `mats.insert(end, ...)` in ia_align_and_median_merge never
# unpoisons its capacity and the next read is reported as a container-overflow. A false positive (README.md).
write_wrapper "$SCRATCH/asan-cli-wrapper.sh" \
  "DYLD_INSERT_LIBRARIES=$SCRATCH/libclang_rt.asan_osx_dynamic.dylib" \
  "MallocNanoZone=0" \
  "ASAN_OPTIONS=detect_container_overflow=0:detect_leaks=0:detect_stack_use_after_return=1:abort_on_error=0"

LOG="$SCRATCH/replay-$FIRST-$LAST.log"
set +e
# shellcheck disable=SC2086
"$STARPIPE" heavy -- "$SCRATCH/asan-cli-wrapper.sh" "$STAR" $ARGS -l info "$STAGE" > "$LOG" 2>&1
STATUS=$?
set -e
echo "exit $STATUS; log $LOG"
echo "ASan reports: $(grep -c 'ERROR: AddressSanitizer' "$LOG" || true), FATAL lines: $(grep -c 'FATAL' "$LOG" || true)"
echo "star-aligned masks computed: $(grep -c 'StarAlignedHorizonMaskCache: computed' "$LOG" || true)"
exit $STATUS
