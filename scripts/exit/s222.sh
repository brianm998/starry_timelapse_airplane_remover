#!/bin/bash
# Checks A1/A2: the built star.app is team-signed with a stable designated requirement.
# Skips when no build exists or the ad-hoc override is set.
set -e
[ "${STAR_TEST_SIGN_IDENTITY-}" = "-" ] && { echo "ad hoc requested; skip"; exit 0; }
app=$(ls -d .build/gui-dd/Build/Products/Debug/star.app 2>/dev/null || true)
[ -n "$app" ] || { echo "no built app; skip"; exit 0; }
codesign -dv "$app" 2>&1 | grep -q "TeamIdentifier=G3L75S65V9"
codesign -d -r- "$app" 2>&1 | grep designated | grep -q "G3L75S65V9"
! codesign -d -r- "$app" 2>&1 | grep -q cdhash
echo ok
