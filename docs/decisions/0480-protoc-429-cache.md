# 0480: cache protoc and lengthen retries instead of apt protoc

The desktop and checkProtoSync jobs download protoc 4.28.3 from Maven Central each run, because setup-gradle is cache-read-only (10 GB budget). A 429 failed both attempts, which were only 20 s apart.

Decision: a separate writable `actions/cache@v4` for `~/.gradle/caches/modules-2/files-2.1/com.google.protobuf/protoc`, keyed on OS and a hash of `star-desktop/build.gradle.kts`; and 4 attempts with 60 s waits.

Not chosen: apt protoc. Ubuntu 24.04 ships 3.21, which does not match the 4.28.3 runtime, and Windows would still need the download.

Caveat: Gradle's resolution metadata lives under `modules-2/metadata-*`, which this cache omits; if CI still downloads, widen the path to all of `modules-2`. The effect only shows on CI.
