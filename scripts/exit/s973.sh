#!/usr/bin/env bash
# s973 exit check for task #985: a file added to a local dependency package is picked up by the next incremental
# build of the dependent package, and unchanged dependency files are not recompiled.
# Self-contained: two trivial scratch packages in a mktemp dir, no star build, no GPU use.
set -euo pipefail
export STAR_USE_GPU_FOR_MERGE=0
FLAG=--disable-build-manifest-caching
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/B/Sources/B" "$tmp/A/Sources/A"
cat > "$tmp/B/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "B", products: [.library(name: "B", targets: ["B"])], targets: [.target(name: "B")])
EOF
cat > "$tmp/A/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "A", dependencies: [.package(path: "../B")],
  targets: [.executableTarget(name: "A", dependencies: [.product(name: "B", package: "B")])])
EOF
echo 'public func base() -> Int { 1 }' > "$tmp/B/Sources/B/Base.swift"
echo 'public func other() -> Int { 2 }' > "$tmp/B/Sources/B/Other.swift"
echo 'import B
print(base())' > "$tmp/A/Sources/A/main.swift"

swift build $FLAG --package-path "$tmp/A" >/dev/null
obj="$(find "$tmp/A/.build" -name 'Other.swift.o' | head -1)"
[ -n "$obj" ] || { echo "FAIL: no Other.swift.o found"; exit 1; }
before="$(stat -f %m "$obj")"
sleep 2

# Add a new file to B and make an existing B file use it.
echo 'public func added() -> Int { 3 }' > "$tmp/B/Sources/B/New.swift"
echo 'public func base() -> Int { added() }' > "$tmp/B/Sources/B/Base.swift"

if ! swift build $FLAG --package-path "$tmp/A" >"$tmp/second.log" 2>&1; then
  cat "$tmp/second.log"
  echo "FAIL: second incremental build with $FLAG did not pick up New.swift"
  exit 1
fi
after="$(stat -f %m "$obj")"
if [ "$before" != "$after" ]; then
  echo "FAIL: unchanged Other.swift was recompiled (incrementality lost)"
  exit 1
fi
echo "s973 OK: new dependency file picked up, untouched files not rebuilt"
