#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Worktree setup (an extension step; starpipe's ARTIFACT_LINKS). star's gitignored build artifacts
# (OpenCV, the decision trees, sample videos and the bundled ffmpeg) exist only in the main checkout,
# so a worktree gets each by symlink. Run in the worktree. The main checkout is where the shared git
# directory lives; override with STAR_MAIN_CHECKOUT.
# Fails (exit 1) when a link cannot be made, and says which. A path that is already right is left alone.
set -euo pipefail
links=(
  opencv/include
  opencv/lib
  opencv/opencv2.framework
  StarDecisionTrees/include
  StarDecisionTrees/lib
  gui/videos
  external_binaries/bin
)
here=$(pwd -P)
main=${STAR_MAIN_CHECKOUT:-}
if [ -z "$main" ]; then
  common=$(git rev-parse --path-format=absolute --git-common-dir)
  main=$(dirname "$common")
fi
main=$(cd "$main" && pwd -P)
if [ "$main" = "$here" ]; then echo "link-artifacts: this is the main checkout; nothing to link"; exit 0; fi
bad=0
for rel in "${links[@]}"; do
  src="$main/$rel"
  dst="$here/$rel"
  if [ ! -e "$src" ]; then echo "link-artifacts: $src does not exist in the main checkout" >&2; bad=1; continue; fi
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then continue; fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then echo "link-artifacts: $dst is in the way" >&2; bad=1; continue; fi
  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst"
  echo "link-artifacts: $rel"
done
exit $bad
