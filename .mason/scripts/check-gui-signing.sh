#!/bin/bash
# Checks the built Star.app is team-signed with a stable designated requirement
# (a team + bundle id requirement, never a cdhash). Skips the team checks when
# STAR_TEST_SIGN_IDENTITY=- (ad hoc). Usage: check-gui-signing.sh [app]
app="${1:-.build/gui-dd/Build/Products/Debug/Star.app}"  # the product is Star.app; /Volumes/sp is case-sensitive
[ -d "$app" ] || { echo "SIGNING-CHECK: no app at $app"; exit 1; }
if [ "${STAR_TEST_SIGN_IDENTITY-}" = "-" ]; then echo "SIGNING-CHECK: ad hoc requested; skipped"; exit 0; fi
codesign -dv "$app" 2>&1 | grep -q "TeamIdentifier=G3L75S65V9" || { echo "SIGNING-CHECK: not signed by team G3L75S65V9"; exit 1; }
req=$(codesign -d -r- "$app" 2>&1 | grep designated)
echo "$req" | grep -q "G3L75S65V9" || { echo "SIGNING-CHECK: requirement lacks the team: $req"; exit 1; }
echo "$req" | grep -q cdhash && { echo "SIGNING-CHECK: requirement is a cdhash: $req"; exit 1; }
echo "SIGNING-CHECK-OK $req"
