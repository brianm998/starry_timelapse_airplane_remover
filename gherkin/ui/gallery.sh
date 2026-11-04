#!/usr/bin/env bash
# Put the two clients' gallery screenshots side by side in <dir>/index.html (see gherkin/ui/README.md, "Parity gallery").
#   gherkin/ui/gallery.sh [dir]        dir defaults to $STAR_GALLERY_DIR, else .test-data/gallery/latest
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dir="${1:-${STAR_GALLERY_DIR:-$root/.test-data/gallery/latest}}"
cd "$root/pipeline"
exec uv run python -m starpipe.gallery "$dir"
