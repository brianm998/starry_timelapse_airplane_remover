#!/usr/bin/env bash
# Fetches the pinned wgpu-native release (https://github.com/gfx-rs/wgpu-native, Apache-2.0/MIT) for this
# machine into wgpu/<platform>/, the way opencv/ and StarDecisionTrees/ keep their prebuilt artifacts:
# git-ignored, provided before the build, and absent on a machine that does not want the wgpu backend
# (StarCpp/Package.swift only builds it when wgpu/<platform>/include exists).
#
#   wgpu/fetch.sh                 this machine's platform
#   wgpu/fetch.sh linux-x86_64    another one (macos-x86_64 macos-aarch64 linux-x86_64 windows-x86_64-msvc)
#
# Each archive is checked against the sha256 GitHub publishes for the release asset, pinned below.
set -euo pipefail

VERSION="v29.0.1.1"
HERE="$(cd "$(dirname "$0")" && pwd)"

sha_for() {
  case "$1" in
    macos-x86_64)         echo 8e2f7378548ddd0e2cf21e7d864dda46e953f0af724855a33778b85ead206d41 ;;
    macos-aarch64)        echo a5797a37b1adf720bcd5dcffb291edbbd5b7b14be0a3874c28e6393a655a7a3e ;;
    linux-x86_64)         echo 95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a ;;
    windows-x86_64-msvc)  echo 7e67d7445c42aeb85e30f88930fd8d7d83ee769e3390aeb1ada75ebf3cf78132 ;;
    *) return 1 ;;
  esac
}

platform="${1:-}"
if [ -z "$platform" ]; then
  arch="$(uname -m)"; [ "$arch" = arm64 ] && arch=aarch64; [ "$arch" = amd64 ] && arch=x86_64
  case "$(uname -s)" in
    Darwin) platform="macos-$arch" ;;
    Linux)  platform="linux-$arch" ;;
    MINGW*|MSYS*|CYGWIN*) platform="windows-x86_64-msvc" ;;
    *) echo "unknown platform $(uname -s)" >&2; exit 1 ;;
  esac
fi
want="$(sha_for "$platform")" || { echo "no pinned release for $platform" >&2; exit 1; }

dest="$HERE/$platform"
if [ -f "$dest/.version" ] && [ "$(cat "$dest/.version")" = "$VERSION" ]; then
  echo "wgpu-native $VERSION already in $dest"; exit 0
fi

zip="wgpu-$platform-release.zip"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "fetching $zip ($VERSION)"
# macOS: the system curl trusts the keychain; a MacPorts/Fink curl earlier on PATH may have no CA bundle.
CURL=curl; [ -x /usr/bin/curl ] && CURL=/usr/bin/curl
"$CURL" -fsSL -o "$tmp/$zip" "https://github.com/gfx-rs/wgpu-native/releases/download/$VERSION/$zip"

if command -v sha256sum >/dev/null; then got="$(sha256sum "$tmp/$zip" | cut -d' ' -f1)"
else got="$(shasum -a 256 "$tmp/$zip" | cut -d' ' -f1)"; fi
[ "$got" = "$want" ] || { echo "sha256 mismatch for $zip: got $got, want $want" >&2; exit 1; }

rm -rf "$dest"; mkdir -p "$dest"
if command -v unzip >/dev/null; then unzip -q "$tmp/$zip" -d "$dest"
else tar -xf "$tmp/$zip" -C "$dest"; fi   # Git Bash on Windows has no unzip; its bsdtar reads zips
echo "$VERSION" > "$dest/.version"
echo "wgpu-native $VERSION -> $dest"; ls "$dest"
