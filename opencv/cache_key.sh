#!/bin/bash
#
# Prints the OpenCV cache key digest used by every actions/cache step in
# .github/workflows. It hashes build.sh and release.sh with full-line comments
# and blank lines removed, so editing a comment does not invalidate the caches;
# only a change to the lines the shell actually runs produces a new digest.
#
# `git hash-object --stdin` keeps this identical on macOS, Linux and Windows
# Git Bash, with no shasum / sha256sum differences. Carriage returns are
# dropped first so a CRLF checkout hashes the same as an LF one.
#
# build.sh has no heredocs, so dropping '#' lines cannot remove meaningful
# content. If one is ever added, revisit this.
set -euo pipefail
cd "$(dirname "$0")"
cat build.sh release.sh | tr -d '\r' | grep -vE '^[[:space:]]*(#|$)' | git hash-object --stdin
