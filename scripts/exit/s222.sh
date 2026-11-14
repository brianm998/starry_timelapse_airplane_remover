#!/bin/bash
# Checks A1/A2 on the built Star.app (skips when no build exists).
[ -d .build/gui-dd/Build/Products/Debug/Star.app ] || [ -d gui/DerivedData/Build/Products/Debug/Star.app ] || { echo "no built app; skip"; exit 0; }
exec .mason/scripts/check-gui-signing.sh
