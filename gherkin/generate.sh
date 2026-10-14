#!/usr/bin/env bash
# Regenerate every generated Gherkin source (Swift kernel, cli/gui test entry points, Kotlin). See README.md.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec swift run --package-path "$here/StarGherkin" star-gherkin-gen --root "$(cd "$here/.." && pwd)" "$@"
