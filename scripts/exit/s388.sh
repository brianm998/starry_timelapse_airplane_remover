#!/bin/bash
set -e
python3 art/export.py --check
for l in a b c d e f g h i j; do test -f art/masters/HP-3$l.png; done
grep -q 'assertEquals(81, StarArt.entries.size)' star-desktop/src/test/kotlin/com/star/desktop/ui/components/StarArtTest.kt
grep -q 'StarArt.allCases.count, 81' gui/starTests/starTests.swift
echo "s388 OK"
