# Bundled native resources

Compose Desktop copies the per-OS subdirectory matching the **build host** into the packaged app and
exposes it at runtime via the `compose.application.resources.dir` system property. We bundle the Swift
daemon and the video tools here so the shipped app is self-contained:

```
app-resources/
  macos-arm64/   stard  ffmpeg  ffprobe
  macos-x64/     stard  ffmpeg  ffprobe
  windows-x64/   stard.exe  ffmpeg.exe  ffprobe.exe
  linux-x64/     stard  ffmpeg  ffprobe
```

`ffmpeg`/`ffprobe` sit **next to `stard`** on purpose: `StarCore.ToolPaths` resolves them as siblings of
the running executable, and `DaemonProcess.resolveStardBinary()` looks here first when packaged — so no
runtime path configuration is needed.

The binaries are **not committed** (large, OS-specific; `.gitignore` excludes the subdirs). Stage them
before packaging:

```bash
# host-OS binaries → app-resources/<os-arch>/  (release stard preferred; falls back to debug)
./gradlew stageAppResources
# build the installer for the current OS
./gradlew packageDistributionForCurrentOS         # .dmg / .exe / .deb
# or just the runnable app image (no installer tooling needed):
./gradlew createDistributable
```

Overrides: `-Pstard=/abs/path/to/stard` and `-Pffmpegdir=/abs/dir/containing/ffmpeg+ffprobe`
(defaults: `daemon/.build/{release,debug}/stard` and repo-root `external_binaries/bin`).

`external_binaries/bin` is where the ffmpeg to bundle goes. It is not committed; build it first, with either of
the two scripts (see `ffmpeg/README.md`):

```bash
./ffmpeg/build_ci.sh external_binaries/bin   # what CI ships: universal on a Mac, x86_64 elsewhere
./ffmpeg/build.sh --install                  # this machine's own build, with its GPU support: VideoToolbox on a Mac,
                                             # NVENC / AMF / Media Foundation / Direct3D on Windows, NVENC / Vulkan on Linux
```

Staging refuses to package an ffmpeg or ffprobe built for a different architecture than the bundle
(an x86_64-only one in an arm64 bundle would package fine and then fail the first time a user opens a
video). To bundle an arm64-only app, thin the universal one: `lipo -thin arm64 in -output out`.

All packaging tasks (`createDistributable` for the app image, and `packageDmg`/`packageExe`/`packageDeb`
for installers) invoke **`jpackage`**, which some JDKs omit — notably the JetBrains Runtime bundled with
Android Studio. Point the packaging step at a full JDK 21+ (with jpackage) without changing the compile
JVM: `-Pstar.jpackage.jdk=/path/to/jdk` or `STAR_JPACKAGE_JDK=/path/to/jdk`. (The binary-staging step,
`stageAppResources` → `prepareAppResources`, needs no jpackage.)

## Signing (macOS)

Signing is opt-in (default builds are unsigned). Pass a Developer ID identity via env (the `gradlew`
wrapper mangles `()` in `-P` values, so prefer env vars here):

```bash
export STAR_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export STAR_JPACKAGE_JDK="/path/to/jdk-21"            # must contain jpackage (the JBR does not)
./gradlew packageDmg -Pcompose.desktop.packaging.checkJdkVendor=false   # the flag is only needed for a Homebrew JDK
```

The `.app` is signed with the hardened runtime + `packaging/macos-entitlements.plist`. jpackage copies
the bundled binaries as *data* (strips +x, leaves them unsigned), so a post-step (`fixBundledBinaries`)
restores the execute bit and codesigns `stard`/`ffmpeg`/`ffprobe`, then re-seals the `.app`. Verify:

```bash
codesign --verify --deep --strict build/compose/binaries/main/app/Star.app   # → valid on disk
```

**Notarization is a separate step** (`xcrun notarytool submit` + `stapler staple`, needs an Apple ID /
app-specific password). Until then `spctl -a` reports "Unnotarized Developer ID" — the signature is valid,
it just hasn't been notarized for Gatekeeper on other machines.

## Per-OS / CI

`stard` is a Swift binary and must be built **on each target OS** (its OpenCV + StarDecisionTrees
artifacts live only in the main checkout, so CI needs them provisioned first). The cross-platform flow is:
build `stard` on macOS / Windows / Linux, drop each into the matching `app-resources/<os-arch>/` on that
runner, then run `packageDistributionForCurrentOS`. ffmpeg/ffprobe must be **portable** builds: CI gets them from
`ffmpeg/build_ci.sh` through `.github/workflows/ffmpeg.yml` (the macOS ones are universal arm64 + x86_64), which
checks that they link only system libraries; `ffmpeg/smoke_test.sh` checks the same for `ffmpeg/build.sh`'s
(`otool -L` / `ldd` / `objdump -p`). Do the same by hand when adding another platform.
