#!/bin/bash
# Re-packs a jpackage-built .deb so the bundled native binaries are executable.
#
# jpackage installs everything under lib/app/resources as plain data (mode 644), so the shipped
# .deb had /opt/star/lib/app/resources/{stard,ffmpeg,ffprobe} unexecutable: DaemonProcess then
# cannot start the engine at all, and every Linux user gets "engine stopped". Compose exposes no
# jpackage --resource-dir (where a postinst or modes could be set), so fix the finished package.
#
# Usage: packaging/fix-deb-modes.sh <file.deb>     (rewrites it in place)
set -euo pipefail

DEB="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
command -v dpkg-deb >/dev/null || { echo "fix-deb-modes: dpkg-deb not found, leaving $DEB unchanged" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

dpkg-deb -R "$DEB" "$TMP/pkg"

fixed=0
while IFS= read -r res; do
  for f in stard ffmpeg ffprobe; do
    if [ -f "$res/$f" ]; then chmod 755 "$res/$f"; fixed=$((fixed + 1)); fi
  done
done < <(find "$TMP/pkg" -type d -path '*/lib/app/resources')

[ "$fixed" -gt 0 ] || { echo "fix-deb-modes: no bundled binaries found in $DEB" >&2; exit 1; }

# xz rather than the build host's default (zstd): readable by every dpkg a user might have.
dpkg-deb --build --root-owner-group -Zxz "$TMP/pkg" "$TMP/fixed.deb" >/dev/null
mv "$TMP/fixed.deb" "$DEB"
echo "fix-deb-modes: made $fixed bundled binaries executable in $(basename "$DEB")"
