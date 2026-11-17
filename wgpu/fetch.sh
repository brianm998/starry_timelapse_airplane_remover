#!/usr/bin/env bash
# Fetches the pinned wgpu-native release (https://github.com/gfx-rs/wgpu-native, Apache-2.0/MIT) for this
# machine into wgpu/<platform>/, the way opencv/ and StarDecisionTrees/ keep their prebuilt artifacts:
# git-ignored, provided before the build, and absent on a machine that does not want the wgpu backend
# (StarCpp/Package.swift only builds it when wgpu/<platform>/include exists).
#
#   wgpu/fetch.sh                 this machine's platform (macos-universal on any Mac)
#   wgpu/fetch.sh linux-x86_64    another one (macos-universal macos-x86_64 macos-aarch64 linux-x86_64
#                                 windows-x86_64-msvc)
#
# On macOS StarCpp links wgpu/macos-universal: the gui's Release archive builds arm64 and x86_64 in one go
# and passes the same library to both links, so a single-architecture release (what macos-x86_64 and
# macos-aarch64 are) leaves the other slice with every wgpu symbol undefined. macos-universal is both
# releases joined with lipo; the per-architecture directories are not used by the build.
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
    Darwin) platform="macos-universal" ;;
    Linux)  platform="linux-$arch" ;;
    MINGW*|MSYS*|CYGWIN*) platform="windows-x86_64-msvc" ;;
    *) echo "unknown platform $(uname -s)" >&2; exit 1 ;;
  esac
fi
if [ "$platform" != macos-universal ]; then
  sha_for "$platform" >/dev/null || { echo "no pinned release for $platform" >&2; exit 1; }
fi

dest="$HERE/$platform"
if [ -f "$dest/.version" ] && [ "$(cat "$dest/.version")" = "$VERSION" ]; then
  echo "wgpu-native $VERSION already in $dest"; exit 0
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# macOS: the system curl trusts the keychain; a MacPorts/Fink curl earlier on PATH may have no CA bundle.
CURL=curl; [ -x /usr/bin/curl ] && CURL=/usr/bin/curl

# fetch_into <platform> <dir>: download the pinned release for <platform>, check its sha256, unpack it into <dir>.
fetch_into() {
  local p="$1" d="$2" want got zip
  want="$(sha_for "$p")" || { echo "no pinned release for $p" >&2; exit 1; }
  zip="wgpu-$p-release.zip"
  echo "fetching $zip ($VERSION)"
  "$CURL" -fsSL -o "$tmp/$zip" "https://github.com/gfx-rs/wgpu-native/releases/download/$VERSION/$zip"
  if command -v sha256sum >/dev/null; then got="$(sha256sum "$tmp/$zip" | cut -d' ' -f1)"
  else got="$(shasum -a 256 "$tmp/$zip" | cut -d' ' -f1)"; fi
  [ "$got" = "$want" ] || { echo "sha256 mismatch for $zip: got $got, want $want" >&2; exit 1; }
  mkdir -p "$d"
  if command -v unzip >/dev/null; then unzip -q "$tmp/$zip" -d "$d"
  else tar -xf "$tmp/$zip" -C "$d"; fi   # Git Bash on Windows has no unzip; its bsdtar reads zips
}

stage="$tmp/stage"
if [ "$platform" = macos-universal ]; then
  # xcrun's lipo, never the first one on PATH: an old MacPorts lipo there rejects -verify_arch.
  fetch_into macos-x86_64 "$tmp/x86_64"
  fetch_into macos-aarch64 "$tmp/arm64"
  diff -r "$tmp/x86_64/include" "$tmp/arm64/include" >/dev/null \
    || { echo "the x86_64 and arm64 releases ship different headers; not joining them" >&2; exit 1; }
  mkdir -p "$stage/lib"
  cp -R "$tmp/arm64/include" "$stage/"
  [ -d "$tmp/arm64/wgpu-native-meta" ] && cp -R "$tmp/arm64/wgpu-native-meta" "$stage/"
  for lib in libwgpu_native.a libwgpu_native.dylib; do
    xcrun lipo -create "$tmp/x86_64/lib/$lib" "$tmp/arm64/lib/$lib" -output "$stage/lib/$lib"
    xcrun lipo "$stage/lib/$lib" -verify_arch x86_64 arm64
  done
else
  fetch_into "$platform" "$stage"
fi

echo "$VERSION" > "$stage/.version"
rm -rf "$dest"; mv "$stage" "$dest"
echo "wgpu-native $VERSION -> $dest"; ls "$dest"
