# 0271: Pin the GUI build location in the wrapper

Status: accepted

Context: this Mac's Xcode preferences set a custom build location, so `-derivedDataPath` alone put products in `gui/DerivedData`, and the checker looked for `star.app` on a case-sensitive volume while the product is `Star.app`.

Decision: command-line build settings override the preference, so `xcodebuild-signed.sh` appends absolute `SYMROOT`/`OBJROOT` under the derived data path. The checker defaults to `Star.app` there, with the old location as a fallback.
