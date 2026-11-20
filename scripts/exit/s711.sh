#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s711.md
[ -f docs/decisions/0704-speed-sheet-scrolls.md ]
grep -q "ScrollView(.vertical)" gui/star/KeypointDivisorStartupView.swift
grep -q "startup.speed.cancel" gui/star/KeypointDivisorStartupView.swift
echo "s711 OK"
