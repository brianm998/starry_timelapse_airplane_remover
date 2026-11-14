#!/bin/bash
# xcodebuild with the signing the GUI suites use. Default: the team's Apple Development
# identity, so macOS privacy approvals (removable volumes) survive rebuilds. Set
# STAR_TEST_SIGN_IDENTITY=- on a machine without the certificate to sign ad hoc.
# Manual signing with no -allowProvisioningUpdates: headless, no Xcode account dialog.
ident="${STAR_TEST_SIGN_IDENTITY-Apple Development}"
[ -n "$ident" ] || ident="Apple Development"
if [ "$ident" = "-" ]; then team=""; else team="G3L75S65V9"; fi
# -IDEBuildLocationStyle=Unique: this Mac's Xcode prefs set a custom, project-relative build location
# (IDEBuildLocationStyle=Custom, IDECustomDerivedDataLocation=DerivedData), which beats -derivedDataPath
# and puts the products in gui/DerivedData; Unique puts them back under -derivedDataPath.
exec xcodebuild -IDEBuildLocationStyle=Unique "$@" CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$ident" "DEVELOPMENT_TEAM=$team"
