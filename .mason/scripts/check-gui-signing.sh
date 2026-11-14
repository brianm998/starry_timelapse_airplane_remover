#!/bin/bash
# Checks the built star.app is team-signed with a stable designated requirement
# (a team + bundle id requirement, never a cdhash). Skips the team checks when
# STAR_TEST_SIGN_IDENTITY=- (ad hoc). Usage: check-gui-signing.sh [app]
app="${1-}"
if [ -z "$app" ]; then
  # xcodebuild resolves a relative -derivedDataPath against the project's folder (gui/), and the product is Star.app.
  for d in .build/gui-dd gui/DerivedData; do
    for n in Star.app star.app; do
      [ -d "$d/Build/Products/Debug/$n" ] && app="$d/Build/Products/Debug/$n" && break 2
    done
  done
  [ -n "$app" ] || app=".build/gui-dd/Build/Products/Debug/Star.app"
fi
[ -d "$app" ] || { echo "SIGNING-CHECK: no app at $app"; exit 1; }
if [ "${STAR_TEST_SIGN_IDENTITY-}" = "-" ]; then echo "SIGNING-CHECK: ad hoc requested; skipped"; exit 0; fi
codesign -dv "$app" 2>&1 | grep -q "TeamIdentifier=G3L75S65V9" || { echo "SIGNING-CHECK: not signed by team G3L75S65V9"; exit 1; }
req=$(codesign -d -r- "$app" 2>&1 | grep designated)
# An Apple Development requirement names the certificate (leaf CN), not the team id; both are stable.
echo "$req" | grep -Eq "G3L75S65V9|certificate leaf\[subject.CN\] = \"Apple Development:" || { echo "SIGNING-CHECK: requirement lacks the team: $req"; exit 1; }
echo "$req" | grep -q cdhash && { echo "SIGNING-CHECK: requirement is a cdhash: $req"; exit 1; }
echo "SIGNING-CHECK-OK $req"
