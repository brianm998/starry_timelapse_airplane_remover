#!/bin/bash
#
# The release-asset tier of CI's OpenCV lookup (.github/workflows/opencv.yml). An OpenCV build made on any
# branch, a PR included, is saved as an asset of the `opencv-prebuilt` pre-release, so every later run finds it:
# actions/cache entries made by a PR are visible to that PR only.
#
#   ci_release_asset.sh download <asset-prefix> <os-dir> <sentinel-lib>   exit 0: opencv/lib/<os-dir> and
#                                                                         opencv/include restored; 1: no such asset
#   ci_release_asset.sh upload   <asset-prefix> <os-dir> <sentinel-lib>   create the release if absent, then
#                                                                         upload (--clobber: a racing build is harmless)
#
# The asset is <asset-prefix>-<cache_key.sh>.tar.gz. The prefix is the actions/cache key prefix (it encodes
# the runner image and, on Windows, the MSVC toolset), so a changed toolchain never matches an old asset.
# Needs GH_TOKEN and GITHUB_REPOSITORY (set by Actions) and the gh CLI. This file is deliberately not part of
# cache_key.sh's digest: editing it does not invalidate a single OpenCV build.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

mode="${1:?mode: download | upload}"
prefix="${2:?asset prefix}"
os_dir="${3:?os dir under lib/}"
sentinel="${4:?library file that proves a complete build}"

tag="opencv-prebuilt"
asset="$prefix-$(./cache_key.sh).tar.gz"

# Relative archive paths only: GNU tar on Windows reads "C:\..." as host:path.
case "$mode" in
download)
    rm -f "$asset"
    if ! gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern "$asset" --dir . 2>/dev/null; then
        echo "no $asset in release $tag"
        exit 1
    fi
    if tar -xzf "$asset" && [ -f "lib/$os_dir/$sentinel" ] && [ -d include ]; then
        rm -f "$asset"
        echo "restored $asset"
        exit 0
    fi
    echo "$asset did not unpack to a complete OpenCV; ignoring it"
    rm -rf "$asset" "lib/$os_dir" include
    exit 1
    ;;
upload)
    [ -f "lib/$os_dir/$sentinel" ] || { echo "no lib/$os_dir/$sentinel to upload"; exit 1; }
    tar -czf "$asset" "lib/$os_dir" include
    if ! gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
        # a parallel run may create it first; the view below decides
        gh release create "$tag" --repo "$GITHUB_REPOSITORY" --prerelease \
            --title "OpenCV prebuilt (CI)" \
            --notes "Static OpenCV builds made by CI (.github/workflows/opencv.yml), one asset per OS and opencv/cache_key.sh digest. Not a product release; safe to delete, CI rebuilds what is missing." \
            || gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null
    fi
    gh release upload "$tag" "$asset" --repo "$GITHUB_REPOSITORY" --clobber
    rm -f "$asset"
    echo "uploaded $asset"
    ;;
*)
    echo "usage: $0 download|upload <asset-prefix> <os-dir> <sentinel-lib>" >&2
    exit 2
    ;;
esac
