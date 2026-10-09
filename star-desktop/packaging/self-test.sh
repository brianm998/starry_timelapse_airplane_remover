#!/bin/bash
# Runs the packaged desktop app's built-in end-to-end self-test (`Star --self-test`, see
# EngineSelfTest.kt) against an app image, the way a user's install would run.
#
# Usage: packaging/self-test.sh <app-image-dir> <work-dir>
#
#   <app-image-dir>  what `gradlew createDistributable` produced (build/compose/binaries/main/app),
#                    i.e. the directory holding Star/ (Windows, Linux) or Star.app (macOS)
#   <work-dir>       scratch space for the fixtures, the engine scratch dir and the report
#
# Meant for a CI job on a FRESH runner: no Swift toolchain, no build tree. That is the point —
# the Windows engine that died after "connecting" worked on every machine that still had its
# build directory, so a test on the build machine could not see it.
#
# Fixtures come from test_data/test_a7sii_10 (tracked in git) and are made with the app's own
# bundled ffmpeg: three 16-bit TIFFs (what the Windows report used) and a short H.264 clip.
set -euo pipefail

APP="$(cd "$1" && pwd)"
WORK="$(mkdir -p "$2" && cd "$2" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/test_data/test_a7sii_10"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    OS=windows; EXE=".exe"
    LAUNCHER="$APP/Star/Star.exe"; RES="$APP/Star/app/resources" ;;
  Darwin)
    OS=macos; EXE=""
    LAUNCHER="$APP/Star.app/Contents/MacOS/Star"; RES="$APP/Star.app/Contents/app/resources" ;;
  *)
    OS=linux; EXE=""
    LAUNCHER="$APP/Star/bin/Star"; RES="$APP/Star/lib/app/resources" ;;
esac

for f in "$LAUNCHER" "$RES/stard$EXE" "$RES/ffmpeg$EXE"; do
  [ -f "$f" ] || { echo "::error::$f is not in the app image"; find "$APP" -maxdepth 4 | head -50; exit 1; }
done
echo "app image ($OS): $APP"
ls -la "$RES"

# A native path for the Windows launcher (MSYS converts most arguments, but not reliably all).
native() { if [ "$OS" = windows ]; then cygpath -w "$1"; else echo "$1"; fi; }

if [ "$OS" = linux ]; then
  # The engine must not lean on a Swift toolchain: a user's machine has none, and a CI runner
  # may have one at exactly the rpath the build used, which would hide the dependency.
  echo "== stard shared libraries:"
  ldd "$RES/stard" | tee "$WORK/ldd.txt"
  if grep -Ei "not found|swift" "$WORK/ldd.txt"; then
    echo "::error::stard depends on a library a user's machine will not have (above)"; exit 1
  fi
fi

SEQ="$WORK/fixture/seq"
CLIP="$WORK/fixture/video/clip.mp4"
rm -rf "$WORK/fixture" "$WORK/scratch"
mkdir -p "$SEQ" "$(dirname "$CLIP")"
FFMPEG="$RES/ffmpeg$EXE"
for n in 80 81 82; do
  "$FFMPEG" -hide_banner -loglevel error -i "$(native "$SRC/LRT_000$n.jpg")" -pix_fmt rgb48le "$(native "$SEQ/LRT_000$n.tif")"
done
"$FFMPEG" -hide_banner -loglevel error -framerate 2 -start_number 80 -i "$(native "$SRC/LRT_%05d.jpg")" \
  -frames:v 6 -vf scale=1280:-2 -c:v libx264 -pix_fmt yuv420p "$(native "$CLIP")"
ls -la "$SEQ" "$(dirname "$CLIP")"

REPORT="$WORK/self-test.txt"
rm -f "$REPORT"
set +e
"$LAUNCHER" --self-test \
  --scratch "$(native "$WORK/scratch")" \
  --report "$(native "$REPORT")" \
  --process \
  --video "$(native "$CLIP")" \
  "$(native "$SEQ")"
code=$?
set -e

# The Windows launcher is a GUI-subsystem exe, so its stdout goes nowhere: the report file is
# the output. It is also the verdict — the exit status is checked too, but the RESULT line is
# what proves the test actually ran to the end.
echo "== self-test report:"
cat "$REPORT" 2>/dev/null || echo "(no report was written)"
echo "== launcher exit status: $code"
grep -q "^RESULT: PASS" "$REPORT" 2>/dev/null || { echo "::error::the self-test did not pass"; exit 1; }
[ "$code" -eq 0 ] || { echo "::error::the launcher exited $code"; exit 1; }
echo "self-test passed"
