#!/bin/bash
# xcodebuild with the signing the GUI suites use. Default: the team's Apple Development
# identity, so macOS privacy approvals (removable volumes) survive rebuilds. Set
# STAR_TEST_SIGN_IDENTITY=- on a machine without the certificate to sign ad hoc.
# Manual signing with no -allowProvisioningUpdates: headless, no Xcode account dialog.
# With -derivedDataPath, SYMROOT/OBJROOT are pinned under it: an Xcode custom build location
# (IDECustomDerivedDataLocation) would otherwise send products to gui/DerivedData.
# Also links the gitignored build artifacts (link-artifacts.sh, idempotent) so the build works in
# any worktree, including ledger worktrees that never ran the setup step. Failure is non-fatal.
bash "$(dirname "$0")/link-artifacts.sh" >&2 || echo "xcodebuild-signed: link-artifacts failed; building anyway" >&2
ident="${STAR_TEST_SIGN_IDENTITY-Apple Development}"
[ -n "$ident" ] || ident="Apple Development"
if [ "$ident" = "-" ]; then team=""; else team="G3L75S65V9"; fi
dd=""; prev=""
for a in "$@"; do
  [ "$prev" = "-derivedDataPath" ] && dd="$a"
  prev="$a"
done
extra=()
if [ -n "$dd" ]; then
  case "$dd" in /*) ;; *) dd="$PWD/$dd" ;; esac
  extra=("SYMROOT=$dd/Build/Products" "OBJROOT=$dd/Build/Intermediates.noindex")
fi
for a in "$@"; do
  if [ "$a" = "test" ] && /usr/bin/pgrep -f /Applications/Star.app/Contents/MacOS/Star >/dev/null 2>&1; then
    echo "xcodebuild-signed: note: /Applications/Star.app is running; the Debug test host is com.star.debug so it should not conflict (t485)" >&2
    break
  fi
done
# The shim in .mason/shims passes straight through when this is set (no loop back into it).
export STAR_XCODEBUILD_SHIM_PASSED=1
exec xcodebuild "$@" ${extra[@]+"${extra[@]}"} CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$ident" "DEVELOPMENT_TEAM=$team"
