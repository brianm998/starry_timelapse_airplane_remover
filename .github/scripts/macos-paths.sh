#!/usr/bin/env bash
# Does a pull request touch anything that is specific to macOS? Reads the PR's changed files (one per line) on stdin and prints
# `true` or `false`. A PR runs the macOS jobs only when this says true; the push to develop and the nightly run them always
# (see "The smoke subset on a PR" in gherkin/README.md). Used by the `changes` jobs of pr-gate.yml, cli.yml and gherkin-smoke.yml.
#
# macOS-specific: what only macOS builds or runs. The Xcode gui (gui/), the Metal/wgpu code (StarCpp/, wgpu/), the Xcode cli
# project, the macOS ffmpeg build (ffmpeg/) and the workflows that define the macOS jobs. Everything else (StarCore/, daemon/,
# star-desktop/, ...) builds and tests the same on Linux, which runs on the PR.
set -euo pipefail
while IFS= read -r f; do
  case "$f" in
    .github/ISSUE_TEMPLATE/*) ;;
    gui/*|StarCpp/*|wgpu/*|cli/*.xcodeproj/*|ffmpeg/*|.github/*)
      echo "Touches macOS-specific path: $f" >&2
      echo true
      exit 0 ;;
  esac
done
echo false
