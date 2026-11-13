#!/bin/bash
# Checks A1/A2 on the built star.app (skips when no build exists).
[ -d .build/gui-dd/Build/Products/Debug/star.app ] || { echo "no built app; skip"; exit 0; }
exec .mason/scripts/check-gui-signing.sh
