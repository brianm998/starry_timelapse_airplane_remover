#!/usr/bin/env bash
# Renames the jpackage output in <dir> to the release names:
#   Star-Desktop_<ver>.dmg, Star-Desktop-<ver>.exe, Star-Desktop_<ver>_<arch>.deb
# <ver> is Config.latestVersion. jpackage's own names differ from these, and the .dmg carries 1.x.y
# because macOS rejects a leading 0 (see macPackageVersion in build.gradle.kts).
set -euo pipefail

dir="${1:?usage: name-installers.sh <dir>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
version="$(sed -n 's/.*static let latestVersion *= *"\([0-9.]*\)".*/\1/p' "$root/StarCore/Sources/StarCore/Config.swift")"
[ -n "$version" ] || { echo "could not read Config.latestVersion" >&2; exit 1; }

cd "$dir"
for f in *; do
    case "$f" in
        *.dmg) new="Star-Desktop_${version}.dmg" ;;
        *.exe) new="Star-Desktop-${version}.exe" ;;
        *.deb) new="Star-Desktop_${version}_${f##*_}" ;;   # keep jpackage's <arch>.deb tail
        *)     continue ;;
    esac
    [ "$f" = "$new" ] || mv -v "$f" "$new"
done
