#!/bin/bash

# Triggers the GitHub Actions release by tagging HEAD and pushing the tag.
#
# .github/workflows/cli.yml listens on `tags: ['release/*']`. Pushing that tag
# is the only thing that runs the two release-gated jobs:
#
#   macos-signed-release  - Developer ID signing + notarization
#   release-publish       - collects every platform's artifact and opens a
#                           DRAFT GitHub Release named "Star <version>"
#
# The draft still has to be published by hand on github.com afterwards.
#
# Note that a manual `workflow_dispatch` run is NOT a substitute: it builds and
# signs, but release-publish is gated on the tag ref alone and never fires.
#
# This script does no building. For local multi-platform builds see ./release.sh
# (which reads the version the same way this does, but leaves tagging to us).

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Preflight checks ──────────────────────────────────────────────────────────
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH"; exit 1; }
}
need_cmd git
need_cmd perl

# ── Version and commit ────────────────────────────────────────────────────────
# version.pl reads Sources/StarCore/Config.swift relative to its own cwd, so it
# has to run from inside StarCore/.
STAR_VERSION=$(cd StarCore && perl version.pl)
GIT_HASH=$(git rev-parse HEAD)
TAG="release/${STAR_VERSION}"

echo "==> star v${STAR_VERSION}  commit ${GIT_HASH}"
echo "==> Tag: ${TAG}"

if [ -z "$STAR_VERSION" ]; then
    echo "ERROR: could not read version from StarCore/Sources/StarCore/Config.swift"
    exit 1
fi

# release-publish takes the release name from the tag, but the per-platform
# build scripts name their packages from version.pl. A tag that disagrees with
# Config.swift silently ships a release titled one version holding files named
# another, so derive the tag rather than accepting one as an argument.
if [ "$#" -gt 0 ]; then
    echo "ERROR: this script takes no arguments; the tag is derived from Config.swift."
    echo "       To release a different version, edit latestVersion in"
    echo "       StarCore/Sources/StarCore/Config.swift and commit that first."
    exit 1
fi

# ── Refuse to re-tag ──────────────────────────────────────────────────────────
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "ERROR: tag '${TAG}' already exists locally (at $(git rev-parse --short "${TAG}"))."
    echo "       Bump latestVersion in StarCore/Sources/StarCore/Config.swift,"
    echo "       or delete the tag: git tag -d ${TAG} && git push origin :${TAG}"
    exit 1
fi
# ls-remote exits 0 when the tag is found and 2 when it isn't, but it also exits
# nonzero (128) when it simply can't reach origin -- no ssh-agent, offline, etc.
# Treat those three cases separately, otherwise an unreachable origin looks
# exactly like "tag is free" and we tag a version that is already released.
set +e
git ls-remote --exit-code --tags origin "${TAG}" >/dev/null 2>&1
LS_REMOTE_RC=$?
set -e
case "$LS_REMOTE_RC" in
    0)
        echo "ERROR: tag '${TAG}' already exists on origin. That version is already released."
        echo "       Bump latestVersion in StarCore/Sources/StarCore/Config.swift."
        exit 1
        ;;
    2)
        : # no such tag on origin, which is what we want
        ;;
    *)
        echo "WARNING: could not reach origin to check for an existing '${TAG}'"
        echo "         (git ls-remote exited ${LS_REMOTE_RC}; ssh-agent not loaded?)."
        echo "         Continuing -- the push below will fail if it is already taken."
        ;;
esac

# ── Warn about anything the tagged commit won't contain ───────────────────────
if ! git diff --quiet HEAD 2>/dev/null; then
    echo "WARNING: working tree has uncommitted changes; the tag points at"
    echo "         ${GIT_HASH} without them."
fi

# The commit must be on origin, otherwise the Actions run builds a commit that
# is reachable only from the tag and the generated release notes come out empty.
if ! git branch -r --contains HEAD 2>/dev/null | grep -q .; then
    echo "WARNING: HEAD is not on any remote branch. Push your branch first so the"
    echo "         release notes generate against real history:  git push"
fi

# ── Tag and push ──────────────────────────────────────────────────────────────
echo ""
echo "==> Tagging ${GIT_HASH} as '${TAG}'..."
git tag -a "$TAG" "$GIT_HASH" -m "Release ${STAR_VERSION}"

echo "==> Pushing '${TAG}' to origin..."
# Roll the local tag back on a failed push, so a retry isn't blocked by the
# local-tag guard above telling you to delete a tag you never meant to keep.
if ! git push origin "$TAG"; then
    echo ""
    echo "ERROR: push failed; removing the local tag '${TAG}' so you can retry."
    git tag -d "$TAG"
    exit 1
fi

echo ""
echo "==> Pushed ${TAG}. GitHub Actions is now building the release."
echo "    Runs:   https://github.com/brianm998/starry_timelapse_airplane_remover/actions"
echo "    Drafts: https://github.com/brianm998/starry_timelapse_airplane_remover/releases"
echo ""
echo "    The release is created as a DRAFT once linux, macos-signed-release and"
echo "    windows all pass; publish it by hand when the artifacts look right."
