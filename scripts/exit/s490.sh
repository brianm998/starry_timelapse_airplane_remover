#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
bash -n gui/appstore_release.sh
grep -q 'xcrun altool --upload-app -f "\$PKG"' gui/appstore_release.sh
! grep -q 'ExportOptions-upload.plist' gui/appstore_release.sh
grep -q 'uploading needs an App Store Connect API key' gui/appstore_release.sh
/usr/bin/ruby -ryaml -e "YAML.load_file('.github/workflows/cli.yml')"
grep -q 'App Store Connect app record' .github/workflows/cli.yml
echo "s490 OK"
