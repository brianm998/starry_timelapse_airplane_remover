#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The parity gallery (an extension step): the macOS app's and the desktop client's screenshots side by
# side in one HTML page. It is advisory and never fails on a difference. star already has
# `gherkin/ui/gallery.sh <dir>` for this (it runs `starpipe.gallery` from pipeline/, so removing pipeline/
# means porting the gallery first), and this step only calls it and prints where the page is.
# Usage: gallery.sh <screenshot dir>
set -euo pipefail
dir=${1:?usage: gallery.sh <screenshot dir>}
gherkin/ui/gallery.sh "$dir"
echo "gallery: $dir/index.html"
