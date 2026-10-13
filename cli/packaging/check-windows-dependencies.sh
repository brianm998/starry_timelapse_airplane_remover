#!/bin/bash
# Checks that every DLL a packaged star.exe needs is in the package, or is part of Windows.
#
# Usage: cli/packaging/check-windows-dependencies.sh <path to star.exe>
#
# Walks the import tables with `dumpbin /dependents`, starting at star.exe and following only the DLLs
# the package carries (so an unused DLL with its own unmet dependencies does not matter), and
# classifies each dependency:
#
#   bundled      a file in the package's directory
#   system       a Windows component: an API-set stub (api-ms-win-*) or a DLL in System32
#   NOT BUNDLED  the Visual C++ runtime (vcruntime140.dll, msvcp140.dll, ...). It is in System32 on a
#                GitHub runner and on most machines, but it is the redistributable's, not Windows': a
#                machine without it cannot start star.exe, so it has to ship in the package
#   MISSING      neither in the package nor in System32
#
# NOT BUNDLED and MISSING fail the check. Delay-loaded imports (only resolved when first called) are
# classified the same way but only warn.
#
# Why this on top of running star.exe: a runner has the VC++ runtime installed, so a package without it
# starts there and not on a user's machine; and a run only reports "exit -1073741515" for the first DLL
# the loader could not find, where this names every one.
#
# It cannot see DLLs loaded at run time with LoadLibrary; running star.exe (self-test.sh) covers those
# that matter.
#
# dumpbin comes from Visual Studio's C++ tools (on GitHub's windows runners); DUMPBIN overrides where.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <path to star.exe>" >&2
  exit 2
fi
fail() { echo "::error::$*"; exit 1; }

[ -f "$1" ] || fail "$1 is not a file"
EXE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
PKG_DIR="$(dirname "$EXE")"

# A native (Windows) path for dumpbin, which does not understand the POSIX paths Git Bash uses.
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }

find_dumpbin() {
  if [ -n "${DUMPBIN:-}" ]; then echo "$DUMPBIN"; return; fi
  local vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  if [ -f "$vswhere" ]; then
    local vs vs_bash ver
    vs="$("$vswhere" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
            -property installationPath 2>/dev/null | tr -d '\r')"
    if [ -n "$vs" ]; then
      vs_bash="$(cygpath -u "$vs")"
      ver="$(tr -d '\r\n' < "$vs_bash/VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt")"
      if [ -f "$vs_bash/VC/Tools/MSVC/$ver/bin/Hostx64/x64/dumpbin.exe" ]; then
        echo "$vs_bash/VC/Tools/MSVC/$ver/bin/Hostx64/x64/dumpbin.exe"; return
      fi
    fi
  fi
  command -v dumpbin.exe 2>/dev/null || command -v dumpbin 2>/dev/null || true
}
DUMPBIN_EXE="$(find_dumpbin)"
[ -n "$DUMPBIN_EXE" ] || fail "dumpbin not found: it comes with Visual Studio's C++ tools (set DUMPBIN to its path)"

if [ -n "${SYSTEM32_DIR:-}" ]; then
  SYSTEM32="$SYSTEM32_DIR"
elif command -v cygpath >/dev/null 2>&1; then
  SYSTEM32="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32"
else
  SYSTEM32="/c/Windows/System32"
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Prints "D <dll>" for each import of $1 and "L <dll>" for each delay-loaded one.
list_dependencies() {
  local out
  # MSYS_NO_PATHCONV: dumpbin's /nologo and /dependents are switches, not POSIX paths to convert.
  out="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$DUMPBIN_EXE" /nologo /dependents "$(native "$1")")" || {
    echo "::error::dumpbin failed on $1" >&2
    return 1
  }
  awk '
    { sub(/\r$/, "") }
    /Image has the following dependencies:/            { mode = "D"; started = 0; next }
    /Image has the following delay load dependencies:/ { mode = "L"; started = 0; next }
    mode != "" {
      if ($0 ~ /^[[:space:]]*$/) { if (started) mode = ""; next }
      if ($0 ~ /^[[:space:]]+[^[:space:]]+\.[dD][lL][lL][[:space:]]*$/) {
        started = 1; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print mode, $0; next
      }
      mode = ""
    }' <<<"$out"
}

# The package's file for a DLL name, matched case-insensitively (Windows names are); empty if none.
bundled_file() { find "$PKG_DIR" -maxdepth 1 -type f -iname "$1" | head -1; }

in_system32() { [ -f "$SYSTEM32/$1" ] || [ -n "$(find "$SYSTEM32" -maxdepth 1 -type f -iname "$1" 2>/dev/null | head -1)" ]; }

# Prints bundled | system | notbundled | missing.
classify() {
  local name lname
  name="$1"; lname="$(lower "$1")"
  if [ -n "$(bundled_file "$name")" ]; then echo bundled; return; fi
  case "$lname" in
    api-ms-win-*|ext-ms-win-*) echo system; return ;;
    vcruntime*|msvcp*|concrt*|vcomp*|vccorlib*) echo notbundled; return ;;
  esac
  if in_system32 "$name"; then echo system; else echo missing; fi
}

echo "dumpbin: $DUMPBIN_EXE"
echo "package: $PKG_DIR"
ERRORS=0
WARNINGS=0
SEEN="|$(lower "$(basename "$EXE")")|"
QUEUE=("$EXE")
index=0
while [ "$index" -lt "${#QUEUE[@]}" ]; do
  file="${QUEUE[$index]}"
  index=$((index + 1))
  echo
  basename "$file"
  # Not a process substitution: its failure would not stop the script.
  dependencies="$(list_dependencies "$file")" || exit 1
  while read -r kind name; do
    [ -n "$name" ] || continue
    status="$(classify "$name")"
    label="$status"
    case "$status:$kind" in
      bundled:*)       label="bundled" ;;
      system:*)        label="system" ;;
      notbundled:D)    label="NOT BUNDLED (Visual C++ runtime: a machine without the redistributable cannot start it)"; ERRORS=$((ERRORS + 1)) ;;
      missing:D)       label="MISSING (not in the package, not a Windows DLL)"; ERRORS=$((ERRORS + 1)) ;;
      notbundled:L|missing:L) label="$status [delay-loaded: only fails if it is called]"; WARNINGS=$((WARNINGS + 1)) ;;
    esac
    printf '    %-40s %s\n' "$name" "$label"
    if [ "$status" = bundled ]; then
      lname="$(lower "$name")"
      case "$SEEN" in
        *"|$lname|"*) ;;
        *) SEEN="$SEEN$lname|"; QUEUE+=("$(bundled_file "$name")") ;;
      esac
    fi
  done <<<"$dependencies"
done

echo
echo "== walked ${#QUEUE[@]} file(s) from $(basename "$EXE")"
UNUSED=""
while IFS= read -r candidate; do
  case "$SEEN" in *"|$(lower "$(basename "$candidate")")|"*) ;; *) UNUSED="$UNUSED $(basename "$candidate")" ;; esac
done < <(find "$PKG_DIR" -maxdepth 1 -type f -iname '*.dll')
[ -z "$UNUSED" ] || echo "not imported by star.exe or anything it needs (loaded at run time, or not needed):$UNUSED"
[ "$WARNINGS" -eq 0 ] || echo "::warning::$WARNINGS delay-loaded dependency(ies) are not in the package (above)"
[ "$ERRORS" -eq 0 ] || fail "$ERRORS dependency(ies) of $(basename "$EXE") would be missing on a machine without Swift or the Visual C++ runtime (above)"
echo "every DLL star.exe needs is in the package or is part of Windows"
