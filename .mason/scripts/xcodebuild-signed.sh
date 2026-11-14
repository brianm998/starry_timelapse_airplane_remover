#!/bin/bash
# xcodebuild with the signing the GUI suites use. Default: the team's Apple Development
# identity, so macOS privacy approvals (removable volumes) survive rebuilds. Set
# STAR_TEST_SIGN_IDENTITY=- on a machine without the certificate to sign ad hoc.
# Manual signing with no -allowProvisioningUpdates: headless, no Xcode account dialog.
ident="${STAR_TEST_SIGN_IDENTITY-Apple Development}"
[ -n "$ident" ] || ident="Apple Development"
if [ "$ident" = "-" ]; then team=""; else team="G3L75S65V9"; fi
# A machine whose Xcode has IDECustomDerivedDataLocation set (this Mac: "DerivedData") ignores
# -derivedDataPath and builds under gui/DerivedData. Pin SYMROOT/OBJROOT under the requested path
# (made absolute: xcodebuild resolves relative roots against the project directory) so the
# products land where the caller and check-gui-signing.sh look.
dd=""
prev=""
for a in "$@"; do
  [ "$prev" = "-derivedDataPath" ] && dd="$a"
  prev="$a"
done
roots=()
if [ -n "$dd" ]; then
  mkdir -p "$dd" && dd="$(cd "$dd" && pwd)"
  roots=("SYMROOT=$dd/Build/Products" "OBJROOT=$dd/Build/Intermediates.noindex")
fi
exec xcodebuild "$@" CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$ident" "DEVELOPMENT_TEAM=$team" "${roots[@]}"
