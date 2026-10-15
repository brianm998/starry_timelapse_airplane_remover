#!/usr/bin/env bash
# Builds a deterministic, content-addressed test-data archive: build_archive.sh <name> <source-dir> [out-dir]
#
# The archive holds one top-level directory called <name>. Entries are sorted, mtimes fixed, owner/group
# zeroed and gzip's name/mtime header omitted, so rebuilding the same files gives the same sha256. Prints
# the file name (<name>-<first 12 hex of sha256>.tar.gz), the full sha256 and the size: exactly what a
# test_data/datasets.json entry needs. Works with GNU tar and with macOS's bsdtar.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: $0 <name> <source-dir> [out-dir]" >&2; exit 2; }
name="$1"; src="$(cd "$2" && pwd)"; out="${3:-.}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
size() { wc -c < "$1" | tr -d ' '; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# A staging copy named <name>, so the archive's top-level directory is right whatever the source is called.
mkdir "$work/stage"; cp -R "$src" "$work/stage/$name"
find "$work/stage/$name" \( -name .DS_Store -o -name '._*' \) -delete
( cd "$work/stage" && find "$name" | LC_ALL=C sort > "$work/list" )

export COPYFILE_DISABLE=1   # no AppleDouble ._ entries from bsdtar
if tar --version 2>&1 | grep -q 'GNU tar'; then
  ( cd "$work/stage" && tar --no-recursion --mtime=@0 --owner=0 --group=0 --numeric-owner -cf "$work/a.tar" -T "$work/list" )
else
  # bsdtar: no --mtime, so stamp the staging tree first.
  find "$work/stage" -exec touch -t 197001010000 {} +
  ( cd "$work/stage" && tar --no-recursion --uid 0 --gid 0 --uname '' --gname '' --no-xattrs --no-acls --no-mac-metadata -cf "$work/a.tar" -T "$work/list" )
fi
gzip -n -9 -c "$work/a.tar" > "$work/a.tar.gz"

full="$(sha "$work/a.tar.gz")"
file="$name-${full:0:12}.tar.gz"
mv "$work/a.tar.gz" "$out/$file"
echo "asset:  $file"
echo "sha256: $full"
echo "bytes:  $(size "$out/$file")"
