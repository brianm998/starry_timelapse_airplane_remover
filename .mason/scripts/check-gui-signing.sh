#!/bin/bash
# Checks the built Star.app is team-signed with a stable designated requirement
# (Apple anchor plus the team or the certificate CN, never a cdhash). Skips the team checks when
# STAR_TEST_SIGN_IDENTITY=- (ad hoc). Usage: check-gui-signing.sh [app]
app="${1:-.build/gui-dd/Build/Products/Debug/Star.app}"  # the product is Star.app; /Volumes/sp is case-sensitive
[ -d "$app" ] || { echo "SIGNING-CHECK: no app at $app"; exit 1; }
if [ "${STAR_TEST_SIGN_IDENTITY-}" = "-" ]; then echo "SIGNING-CHECK: ad hoc requested; skipped"; exit 0; fi
codesign -dv "$app" 2>&1 | grep -q "TeamIdentifier=G3L75S65V9" || { echo "SIGNING-CHECK: not signed by team G3L75S65V9"; exit 1; }
req=$(codesign -d -r- "$app" 2>&1 | grep designated)
# Xcode's default requirement for an Apple Development certificate names the leaf's CN, not the team:
# still one requirement for every build and worktree, which is what makes a privacy Allow stick.
echo "$req" | grep -q 'anchor apple generic' || { echo "SIGNING-CHECK: requirement lacks the Apple anchor: $req"; exit 1; }
echo "$req" | grep -Eq 'G3L75S65V9|certificate leaf\[subject\.CN\] = "Apple Development: ' || { echo "SIGNING-CHECK: requirement names neither the team nor the certificate: $req"; exit 1; }
echo "$req" | grep -q cdhash && { echo "SIGNING-CHECK: requirement is a cdhash: $req"; exit 1; }
echo "SIGNING-CHECK-OK $req"
