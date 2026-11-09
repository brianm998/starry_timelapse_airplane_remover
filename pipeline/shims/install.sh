#!/bin/bash
# Put the xcodebuild and caffeinate shims first on the pipeline daemon's PATH (its launchd plist) and restart the daemon.
set -euo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
dest="$HOME/.star-pipeline/shims"
plist="$HOME/Library/LaunchAgents/com.brianm998.starpiped.plist"
mkdir -p "$dest"
install -m 755 "$here/xcodebuild" "$dest/xcodebuild"
install -m 755 "$here/caffeinate" "$dest/caffeinate"
if ! /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:PATH" "$plist" | grep -q "^$dest:"; then
  old="$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:PATH" "$plist")"
  /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:PATH $dest:$old" "$plist"
fi
echo "shims installed in $dest and first on the daemon's PATH; restart the daemon: launchctl bootout/bootstrap gui/$(id -u)/com.brianm998.starpiped"
