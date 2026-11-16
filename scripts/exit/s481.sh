#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -n "exclusive" .mason/mason.toml
echo "s481 OK"
