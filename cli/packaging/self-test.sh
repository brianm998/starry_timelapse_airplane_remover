#!/bin/bash
# Runs an INSTALLED star CLI the way a user's machine would, and checks it is whole.
#
# Usage: cli/packaging/self-test.sh <star-executable> <work-dir> [--help-only]
#
#   <star-executable>  the star (star.exe) the .deb / .pkg / .zip / setup.exe put on the machine
#   <work-dir>         scratch space for the fixture copy and the output
#   --help-only        skip the processing run (the Windows setup.exe is tested after the zip, which
#                      has already processed the sequence)
#
# Meant for a CI job on a FRESH runner: no Swift toolchain, no build tree. That is the point. SwiftPM's
# generated `Bundle.module` finds a resource folder that is missing from the package by falling back
# to the absolute path of the build directory, so a star shipped without its resources works on every
# machine that built it — the build job, the developer's Mac — and dies or prints message keys on every
# other. A test that runs on the build machine cannot see that.
#
# What it checks, each of which fails differently when something is missing from the package:
#   * the executable starts with nothing of the build machine's environment (a missing runtime DLL or
#     shared library kills it before it can print anything);
#   * `--help` prints text, in English and in Spanish, not message keys (the localization tables are
#     StarCore_StarCore.resources/Localizations; without them every string is its own key);
#   * `--list-languages` lists the shipped languages (languages.json is in the same folder);
#   * unless --help-only, it processes the tracked 19-frame sequence in test_data/test_a7sii_10.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <star-executable> <work-dir> [--help-only]" >&2
  exit 2
fi
STAR_IN="$1"
WORK_IN="$2"
MODE="${3:-}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/test_data/test_a7sii_10"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  Darwin)               OS=macos ;;
  *)                    OS=linux ;;
esac

fail() { echo "::error::$*"; exit 1; }

[ -f "$STAR_IN" ] || fail "$STAR_IN is not a file"
STAR="$(cd "$(dirname "$STAR_IN")" && pwd)/$(basename "$STAR_IN")"
WORK="$(mkdir -p "$WORK_IN" && cd "$WORK_IN" && pwd)"
EXE_DIR="$(dirname "$STAR")"
echo "star ($OS): $STAR"
ls -la "$EXE_DIR"

# ── the package carries its resources where star looks for them ──────────────────────────────────
# The places StarResources.candidateDirectories() searches, in the layouts the packages use: beside
# the executable (Windows zip/setup) and <prefix>/share/star for <prefix>/bin/star (.deb, macOS pkg).
# Checked here as well as by the behaviour below because "the folder is not in the package" is a far
# better error than "the help text is wrong".
RESOURCES=""
for dir in "$EXE_DIR/StarCore_StarCore.resources" \
           "$EXE_DIR/StarCore_StarCore.bundle" \
           "$EXE_DIR/../share/star/StarCore_StarCore.resources"; do
  if [ -f "$dir/Localizations/en.json" ]; then RESOURCES="$dir"; break; fi
done
[ -n "$RESOURCES" ] || fail "no StarCore_StarCore.resources beside $STAR or in ../share/star — the package would print message keys instead of text"
echo "resources: $RESOURCES"
ls "$RESOURCES"
[ -f "$RESOURCES/Localizations/es.json" ] || fail "$RESOURCES/Localizations/es.json is missing"
if [ "$OS" = macos ]; then
  [ -d "$RESOURCES/tile_classifier.mlmodelc" ] || fail "$RESOURCES/tile_classifier.mlmodelc is missing"
fi

if [ "$OS" = windows ]; then
  # The Swift runtime is not on a user's machine. A missing DLL ends the process before it prints.
  for dll in swiftCore.dll Foundation.dll; do
    [ -f "$EXE_DIR/$dll" ] || fail "$dll is not beside star.exe — star.exe will not start on a machine without Swift"
  done
fi

if [ "$OS" = linux ]; then
  # star is built -static-stdlib. A runner may have a Swift toolchain at exactly the rpath the build
  # used, which would hide a dependency on it; a user's machine will not.
  echo "== star shared libraries:"
  ldd "$STAR" | tee "$WORK/ldd.txt"
  if grep -Ei "not found|swift" "$WORK/ldd.txt"; then
    fail "star depends on a library a user's machine will not have (above)"
  fi
fi

# ── run star with nothing of the build machine's environment ─────────────────────────────────────
# No Swift toolchain on PATH, no STAR_RESOURCES_DIR, no leftover build variables; and a working
# directory with nothing in it.
CLEAN_CWD="$WORK/cwd"
mkdir -p "$CLEAN_CWD" "$WORK/home"
run_clean() {
  case "$OS" in
    windows) (cd "$CLEAN_CWD" && env -i SystemRoot="${SYSTEMROOT:-C:\\Windows}" \
                PATH="/c/Windows/System32:/c/Windows" "$STAR" "$@") ;;
    *)       (cd "$CLEAN_CWD" && env -i HOME="$WORK/home" PATH="/usr/bin:/bin" LANG=C "$STAR" "$@") ;;
  esac
}

# Runs star with the arguments, leaving its output in $OUT and its exit status in $CODE.
OUT=""
CODE=0
star_output() {
  CODE=0
  OUT="$(run_clean "$@" 2>&1)" || CODE=$?
}

# A message key looks like cli.help.clean_method. With the tables missing, every string is its key.
has_message_keys() {
  grep -Eq '(^|[^[:alnum:]_.-])cli\.[a-z_]+\.[a-z0-9_]+' <<<"$1"
}

check_help() { # <label> <phrase the translated help must contain> <star arguments...>
  local label="$1" phrase="$2"
  shift 2
  star_output "$@"
  echo "== star $* -> exit $CODE"
  head -12 <<<"$OUT"
  [ "$CODE" -eq 0 ] || fail "$label: star exited $CODE (0xC0000135 = -1073741515 is a missing DLL; a Swift 'Fatal error' is a missing resource bundle)"
  if has_message_keys "$OUT"; then
    fail "$label: the help prints message keys instead of text — StarCore's localization tables were not found"
  fi
  grep -qF -- "$phrase" <<<"$OUT" || fail "$label: the help does not contain \"$phrase\""
}

star_output --version
echo "== star --version -> exit $CODE: $OUT"
[ "$CODE" -eq 0 ] || fail "star --version exited $CODE"

# The phrases are the first line of cli.help.image_sequence_dirname in Localizations/en.json and es.json.
check_help "english help" "Image sequence dirname to process" --language en --help
EN_HELP="$OUT"
check_help "spanish help" "Nombre del directorio de la secuencia" --language es --help
[ "$OUT" != "$EN_HELP" ] || fail "--language es printed the same help as --language en"
# No --language: whatever the machine's own language picks. Only the flag name is language-independent.
check_help "default help" "--language" --help

star_output --list-languages
echo "== star --list-languages -> exit $CODE"
head -5 <<<"$OUT"
[ "$CODE" -eq 0 ] || fail "--list-languages exited $CODE"
LANGUAGE_COUNT="$(wc -l <<<"$OUT" | tr -d ' ')"
[ "$LANGUAGE_COUNT" -ge 20 ] || fail "--list-languages listed $LANGUAGE_COUNT language(s), expected the 22 star ships (languages.json was not found)"
grep -Eq '^[ *] es ' <<<"$OUT" || fail "--list-languages does not list es"

if [ "$MODE" = "--help-only" ]; then
  echo "self-test passed (help only)"
  exit 0
fi

# ── process the tracked sequence ─────────────────────────────────────────────────────────────────
# What the build jobs' smoke test does, on the installed star. A copy, so nothing is written into the
# checkout, and under the same directory name as the smoke test.
rm -rf "$WORK/test_a7sii_10" "$WORK/star-output"
cp -R "$SRC" "$WORK/test_a7sii_10"
echo "== star -l info test_a7sii_10 star-output"
(cd "$WORK" && "$STAR" -l info test_a7sii_10 star-output)
ACTUAL="$(ls -1 "$WORK/star-output" | wc -l | tr -d ' ')"
if [ "$ACTUAL" -ne 19 ]; then
  ls -la "$WORK/star-output" || true
  fail "expected 19 output files, got $ACTUAL"
fi
echo "self-test passed ($ACTUAL/19 output files)"
