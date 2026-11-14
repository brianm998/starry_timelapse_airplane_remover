#!/bin/bash
set -e
bash -n .mason/scripts/xcodebuild-signed.sh
bash -n .mason/scripts/check-gui-signing.sh
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
printf '#!/bin/bash\necho "$@"\n' > "$t/xcodebuild"; chmod +x "$t/xcodebuild"
out=$(PATH="$t:$PATH" .mason/scripts/xcodebuild-signed.sh -derivedDataPath .build/gui-dd build)
echo "$out" | grep -q "SYMROOT=$PWD/.build/gui-dd/Build/Products" || { echo "FAIL SYMROOT: $out"; exit 1; }
echo "$out" | grep -q "OBJROOT=$PWD/.build/gui-dd/Build/Intermediates.noindex" || { echo "FAIL OBJROOT"; exit 1; }
out=$(PATH="$t:$PATH" .mason/scripts/xcodebuild-signed.sh build)
echo "$out" | grep -q SYMROOT && { echo "FAIL: SYMROOT without derivedDataPath"; exit 1; }
.mason/scripts/check-gui-signing.sh "$t/none" | grep -q "no app" || { echo "FAIL no-app"; exit 1; }
mkdir -p "$t/Star.app"
STAR_TEST_SIGN_IDENTITY=- .mason/scripts/check-gui-signing.sh "$t/Star.app" | grep -q skipped || { echo "FAIL find"; exit 1; }
echo "s276 OK"
