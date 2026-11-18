#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
bash -n gui/appstore_release.sh
grep -q 'APPSTORE_FFMPEG_DIR' gui/appstore_release.sh
grep -q "grep -a -q -- '--enable-gpl'" gui/appstore_release.sh
/usr/bin/ruby -ryaml -e "YAML.load_file('.github/workflows/cli.yml')"
grep -q 'needs: \[ffmpeg-lgpl\]' .github/workflows/cli.yml
grep -q 'ffmpeg-macos-universal-lgpl' .github/workflows/cli.yml
bash scripts/exit/s490.sh
echo "s590 OK"
