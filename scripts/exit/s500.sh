#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "moveWithRetry" StarCore/Sources/StarCore/VideoFrameSource.swift
grep -q "^Summary: " docs/stages/s500.md
test -f docs/decisions/0493-windows-ui-shard-red.md
echo "s500 OK"
