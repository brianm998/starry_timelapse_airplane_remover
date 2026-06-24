#!/usr/bin/env bash
#
# Regenerate the Swift protobuf bindings (Sources/StarDaemonMessages/star.pb.swift)
# from proto/star.proto. Run from anywhere; mirror the client copy afterwards with
#   (cd ../star-desktop-v2 && ./gradlew syncProto)
#
# Why the post-process: protoc-gen-swift built with Swift 6.2 (e.g. 1.38.0) emits the
# `nonisolated` modifier on the generated TYPES (enum/struct/extension). That syntax only
# compiles with a Swift 6.2 compiler, so it breaks any pre-6.2 toolchain — including the
# macos-14 / Xcode<=6.1 GitHub runner (the `macos-signed` job in kotlin-client.yml). We
# strip the type-level `nonisolated` so the file compiles on Swift 6.0+. It's a no-op
# semantically: the StarDaemonMessages module has no default actor isolation, so the
# generated types are nonisolated regardless. `nonisolated(unsafe)` (valid since Swift 6.0)
# is preserved — only `nonisolated ` (with a trailing space) is removed.
set -euo pipefail
cd "$(dirname "$0")"

OUT="Sources/StarDaemonMessages/star.pb.swift"
protoc --proto_path=proto --swift_out=Sources/StarDaemonMessages --swift_opt=Visibility=Public proto/star.proto

tmp="$(mktemp)"
sed 's/nonisolated //g' "$OUT" > "$tmp" && mv "$tmp" "$OUT"

echo "Regenerated + normalized $OUT (stripped Swift-6.2-only 'nonisolated' type modifiers)"
