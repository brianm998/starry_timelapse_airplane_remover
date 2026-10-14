# FFmpeg for Star

Star imports and exports video through `ffmpeg` and `ffprobe`. This directory builds the pair it
ships: static, GPL, with hardware acceleration compiled in, for macOS (arm64 + x86_64 in one
universal binary), Linux and Windows.

They are **built, not committed and not downloaded**. The one that used to be committed in
`external_binaries/bin` was an x86_64-only third-party build, which fails on every Apple silicon Mac
that does not have Rosetta installed (`Bad CPU type in executable`, which shows up in the app as a
video that will not load), and gave Windows and Linux nothing at all.

## Two build scripts

| Script | Builds | Used by |
|---|---|---|
| `build_ci.sh` | FFmpeg 7.1.1, GPL, x264/x265/libvpx/lame/opus; macOS universal (VideoToolbox), Linux and Windows x86_64 | **the installers**: `.github/workflows/ffmpeg.yml`, reused by `cli.yml` and `kotlin-client.yml`. It has been through CI on all three platforms |
| `build.sh` (with `lib/`, `versions.env`, `smoke_test.sh`) | FFmpeg 9.0.2 with the GPU encoders compiled in (NVENC/AMF/D3D/Media Foundation/Vulkan; the rest of this file), plus Linux arm64 | local builds (`./ffmpeg/build.sh --install`) and `.github/workflows/ffmpeg-gpu.yml`, which validates the recipe but ships nothing |

The rest of this file describes `build.sh`. Its Linux and Windows recipes have not yet run in CI; once
`ffmpeg-gpu.yml` is green on all three, `cli.yml` and `kotlin-client.yml` can switch to its artifacts
(`ffmpeg-macos-universal`, `ffmpeg-linux-x64`, `ffmpeg-windows-x64`) and `build_ci.sh` can go. Either way
Star finds the runtime's encoders by asking the binary (`FFmpegCapabilities`), so the app works with both.

## Where it is used

| Product | Where the tools live | Needs them? |
|---|---|---|
| `Star.app` (Xcode project) | `Contents/MacOS/`, copied from `external_binaries/bin` by the project | yes: video import and export |
| desktop app (`star-desktop`) | beside `stard` in the bundle, staged by `./gradlew stageAppResources` | yes |
| `stard` | beside the running executable | yes |
| `star` (CLI) | – | no: it only reads and writes image sequences |

`StarCore.ToolPaths` finds them: `$STAR_FFMPEG_DIR` if set, else beside the running executable, else
`<repo>/external_binaries/bin` for a SwiftPM build, else `PATH`. If one cannot be started the error
says why (including "built for x86_64, but star is running as arm64").

## What is in them

FFmpeg **9.0.2**, `--enable-gpl`, linked fully statically (macOS: system frameworks only; Windows:
nothing but Windows; Linux: glibc only). Versions and checksums are pinned in `versions.env`.

| | |
|---|---|
| H.264 | x264 (8- and 10-bit) |
| HEVC | x265 (8-, 10- and 12-bit) |
| AV1 | SVT-AV1 (encode), dav1d (decode: FFmpeg's own AV1 decoder only works through hardware) |
| VP8 / VP9 | libvpx |
| ProRes, DNxHD/HR, FFV1, MJPEG, PNG/TIFF/EXR, ... | FFmpeg's own |

Left out on purpose: audio libraries, subtitle and filter libraries, the capture devices, `libfdk-aac`
(non-free: it would make the binary unredistributable). Star keeps the sound of an imported video as it
came whenever it can, so it rarely encodes audio; when a container will not take the original (WebM takes only
Opus, QuickTime refuses FLAC and Opus, an MP4 is only worth AAC) it uses FFmpeg's own AAC encoder, or its
Opus encoder for WebM, and `AudioSidecar` works out which by asking ffmpeg. Compared with the old build that drops `libaom-av1` (AV1 is SVT-AV1 now),
`libopenh264`, `libxvid`, `libtheora`, `libxavs`, `libwebp` and `libopenjpeg` (the native JPEG 2000
encoder remains).

## Hardware

Every GPU API is loaded **at run time** (`dlopen` / `LoadLibrary`), so the same binary runs on a machine
with the hardware and one without; building needs only the vendors' headers. The header versions are
pinned for the oldest drivers that work (NVENC: driver 530.41.03 / 531.61).

| | macOS | Windows x64 | Linux |
|---|---|---|---|
| **Encode, offered in the Render Video dialog** | VideoToolbox: H.264, HEVC, ProRes | NVENC (NVIDIA) and AMF (AMD): H.264, HEVC, AV1 | NVENC: H.264, HEVC, AV1 |
| Built in, not driven by star yet | – | Media Foundation encoders, Direct3D 11/12 and DXVA2 decode, Vulkan | Vulkan |

The dialog lists an encoder only if this ffmpeg has it **and it starts on this machine**:
`FFmpegCapabilities` runs each hardware encoder once on a few black frames when the app starts, so a PC
without an NVIDIA GPU never sees NVENC, and a Mac never sees AMF. It only offers pixel formats a folder
of TIFFs can actually be converted to (the encoders' GPU surface formats are listed first in ffmpeg's own
tables and would otherwise have been the default).

Hardware encoders are run with sensible quality defaults, because the dialog has no quality control: NVENC at
constant quality (FFmpeg's own default is a 2 Mbit/s target, far too low for 4K; see `defaultQualityArguments`).
VideoToolbox's default measured better than libx264's (47.0 dB vs 44.5 dB PSNR on a 4K sequence), and AMF
chooses its own rate control.

**Decoding is software unless you ask.** Hardware decode (`-hwaccel`) is not bit-identical: on an
Apple silicon Mac, VideoToolbox decoding of 8-bit H.264, ProRes and VP9 differed from the software
decoders by up to a sixth of full scale, in streams tagged BT.709 limited range as well as untagged ones
(HEVC was identical). Star turns decoded frames into TIFFs and re-encodes with the software colour
conversion, so a quietly different decode is a quietly different colour in the finished video. Set
`STAR_FFMPEG_HWACCEL=videotoolbox` (or `cuda`, `d3d11va`, `auto`, ...) to opt in for a long 8K HEVC import
where the speed matters more.

Left out on purpose:

* **VAAPI** (Linux Intel/AMD): FFmpeg links libva rather than loading it, so a binary that has it will not
  start on a machine without libva, and a statically linked libva cannot find its drivers. Star does not drive
  VAAPI encoders yet (they need a device and an upload filter). To use it, point `STAR_FFMPEG_DIR` at a
  distribution ffmpeg.
* **Intel Quick Sync / `libvpl`**: Media Foundation reaches Intel's encoder on Windows already.
* **Metal filters**: need Apple's separately downloaded Metal toolchain, and add only filters star does not use.
* **Windows on Arm** runs the x64 build under emulation; a native one needs separate toolchain work.

## Building

```bash
./ffmpeg/build.sh                    # this machine's native target (universal on a Mac)
./ffmpeg/build.sh --install          # ... and copy it to external_binaries/bin
./ffmpeg/build.sh macos-arm64        # one slice (faster); also macos-x64, linux-x64, linux-arm64, windows-x64
./ffmpeg/smoke_test.sh --target macos-universal ffmpeg/dist/macos-universal
```

Results go to `ffmpeg/dist/<target>/` (`ffmpeg`, `ffprobe`, `LICENSE-ffmpeg.txt`, `BUILDINFO.txt`); sources and
build trees go to `ffmpeg/.work/` (both git-ignored). Steps are stamped, so a re-run only rebuilds what changed.

Prerequisites: a C/C++ compiler, `git`, `curl`, `make`, `cmake`, `meson`, `ninja`, `pkg-config`, and `nasm` for
x86_64 targets (without it the codecs fall back to C and encode several times slower).

| | |
|---|---|
| macOS | Xcode command line tools, `brew install nasm pkgconf meson ninja cmake`. An arm64 Mac cross-compiles the x86_64 slice. |
| Linux | `sudo apt-get install build-essential nasm pkg-config cmake meson ninja-build git curl xz-utils` |
| Windows | an MSYS2 **MINGW64** shell with `base-devel git curl xz diffutils file` and the `mingw-w64-x86_64-` `toolchain nasm cmake ninja meson pkgconf` packages |

`start_development.sh` builds it for the active architecture; `release_darwin.sh` builds the universal one;
`preflight.sh` stops `gui/release.sh` and `gui/local_release.sh` up front if it is missing or lacks a slice.

### CI

`.github/workflows/ffmpeg.yml` builds and smoke-tests every platform, caches the result on a hash of
`versions.env`, `build.sh` and `lib/`, and runs whenever `ffmpeg/` changes. `cli.yml` (the signed macOS
release) and `kotlin-client.yml` call it and download the universal macOS artifact.

### Verification status

| | |
|---|---|
| macOS arm64 | Built here and smoke-tested (`smoke_test.sh`, 54 checks incl. VideoToolbox encode and decode on an M5 Max), and exercised through StarCore's decode and encode paths. |
| macOS x86_64 slice | Cross-compiled here and checked structurally (architecture, linkage); **not run**, the machine has no Rosetta. CI tries it under Rosetta. |
| Linux, Windows | Recipes and CI jobs are written, **not yet run**. They are exercised by `ffmpeg.yml`; expect a first run to need a fix or two. |

## Changing it

* **A new FFmpeg or codec library**: edit `versions.env` (a checksum, or for x264/SVT-AV1/libvpx a git commit), then
  regenerate the Swift tables (below) and commit them with it.
* **A new codec**: add the dependency recipe in `lib/deps.sh`, enable it in `ffmpeg_common_args` in `lib/targets.sh`,
  and add it to the checks in `smoke_test.sh`.
* **A GPU API**: `lib/targets.sh` (flags) and `versions.env` (headers). Anything the Render Video dialog should
  offer also needs a table entry; see below.

### The Swift tables

`FFmpegCodec.swift`, `FFmpegPixelFormat.swift` and `FFmpegMuxer.swift` in `StarCore` describe ffmpeg to the Render
Video dialog. They are generated from FFmpeg itself and have to be regenerated when FFmpeg or its codecs change:

```bash
./StarCore/regenerate_ffmpeg_tables.sh      # on a Mac
```

It builds the `tables` target here (the native build plus AMD's AMF encoders, which compile anywhere) and runs the
generators and `muxer_codecs.c` against that one build, so the three agree. The output is deterministic: a second
run changes nothing, so a diff after a version bump is the real change.

NVIDIA's NVENC cannot be built on a Mac (FFmpeg's configure refuses), so its three encoders come from
`StarCore/ffmpeg_extra_encoders.txt`, written by hand and **checked against the real Linux and Windows binaries in CI**
(`check_extra_encoders.sh`), so a wrong line fails there rather than in a user's export.

## Licence

The result is GPL (x264 and x265 are GPL), which star's own GPLv3 permits. Each build writes `LICENSE-ffmpeg.txt` and a
`BUILDINFO.txt` with the exact `configure` line and every source URL and commit, which is the corresponding-source
offer. Nothing non-free is linked.
