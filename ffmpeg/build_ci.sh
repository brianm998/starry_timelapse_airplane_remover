#!/bin/bash
# The one place ffmpeg + ffprobe are built, for every platform Star ships on: Linux and Windows
# (MSYS2 MINGW64) build x86_64 against the system's static codec libraries; macOS builds the codec
# libraries itself and produces a universal (arm64 + x86_64) binary, so it needs no Rosetta and
# works on any Mac. CI runs this through .github/workflows/ffmpeg.yml (reused by kotlin-client.yml
# and cli.yml); nothing is committed. The Xcode GUI project reads external_binaries/bin, which is
# git-ignored: for a local GUI build, create it with
#   ffmpeg/build_ci.sh external_binaries/bin
#
# Usage: ffmpeg/build_ci.sh <output-dir>      (run from anywhere; clones FFmpeg into a temp dir)
#
# GPL build with the same codecs on every platform (x264/x265/vpx/mp3lame/opus; macOS also gets
# VideoToolbox/AudioToolbox: hardware H.264/HEVC/ProRes encode and decode on the Mac's media engine/GPU). No --enable-nonfree / fdk-aac: the result is redistributable.
set -euo pipefail

OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
FFMPEG_TAG="${FFMPEG_TAG:-n7.1.1}"
WORK="${FFMPEG_WORK:-$(mktemp -d)}"   # set FFMPEG_WORK to a directory to keep/reuse the macOS codec builds
mkdir -p "$WORK"
cd "$WORK"

# ─── macOS: universal build ──────────────────────────────────────────────────────────────────────
# Each architecture is built (and cross-compiled when it isn't the host's) against its own static
# codec libraries, then the two ffmpeg/ffprobe are joined with lipo. Needs Xcode's command line
# tools, cmake and nasm (every codec library is built from a pinned source revision below).
build_darwin() {
  local MIN_MACOS="11.0" HOST_ARCH; HOST_ARCH="$(uname -m)"
  local JOBS; JOBS="$(sysctl -n hw.ncpu)"
  local X264_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55
  local LAME_COMMIT=1f5cc9487284d5950343aa5d4f70de433468070a   # lame 3.100 (sourceforge is unreliable)
  local OPUS_TAG=v1.5.2 VPX_TAG=v1.15.0 X265_VER=4.1
  export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  # Apple's binutils first: MacPorts/Homebrew's `strings`, `ar`, `libtool`... can't read arm64 objects,
  # which fails x264's endianness probe (and would produce unusable archives).
  mkdir -p "$WORK/bin"
  for t in strings ar ranlib libtool nm lipo strip otool; do ln -sf "/usr/bin/$t" "$WORK/bin/$t"; done
  export PATH="$WORK/bin:$PATH"
  for t in cmake nasm make clang pkg-config; do command -v "$t" >/dev/null || { echo "missing build tool: $t" >&2; exit 1; }; done

  local SRC="$WORK/deps"; mkdir -p "$SRC"; cd "$SRC"
  if [ ! -d x264 ]; then
  git clone -q https://code.videolan.org/videolan/x264.git x264 && git -C x264 checkout -q "$X264_COMMIT"
  git clone -q https://github.com/lameproject/lame.git lame && git -C lame checkout -q "$LAME_COMMIT"
  git clone -q --depth 1 --branch "$OPUS_TAG" https://github.com/xiph/opus.git opus
  git clone -q --depth 1 --branch "$VPX_TAG" https://github.com/webmproject/libvpx.git libvpx
  curl -fsSL "https://bitbucket.org/multicoreware/x265_git/downloads/x265_$X265_VER.tar.gz" | tar xz
  # x265 4.1 sets CMP0025/CMP0054 to OLD, which CMake 4 (the CI runner's) refuses outright. NEW is what
  # every packager builds with, but under NEW Apple's clang reports as "AppleClang", so the one exact
  # match on "Clang" (which sets CLANG, and with it the clang flags) has to become a regex match.
  sed -i '' -e 's/\(CMP0025\) OLD/\1 NEW/' -e 's/\(CMP0054\) OLD/\1 NEW/' \
    -e 's/COMPILER_ID} STREQUAL "Clang"/COMPILER_ID} MATCHES "Clang"/' "x265_$X265_VER/source/CMakeLists.txt"
  git clone -q --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git ffmpeg
  fi

  local ARCH
  for ARCH in arm64 x86_64; do
    local P="$WORK/prefix-$ARCH" B="$WORK/build-$ARCH"
    local GNU_HOST CMAKE_PROC VPX_TARGET
    if [ "$ARCH" = arm64 ]; then GNU_HOST=aarch64-apple-darwin; CMAKE_PROC=aarch64; VPX_TARGET=arm64-darwin20-gcc
    else GNU_HOST=x86_64-apple-darwin; CMAKE_PROC=x86_64; VPX_TARGET=x86_64-darwin20-gcc; fi
    local CC="clang -arch $ARCH -mmacosx-version-min=$MIN_MACOS"
    mkdir -p "$P" "$B"
    # x265 assembles its arm64 NEON files with ${CMAKE_CXX_COMPILER} directly, ignoring CMAKE_OSX_ARCHITECTURES,
    # so when cross-compiling the compiler itself has to carry the -arch.
    printf '#!/bin/sh\nexec clang -arch %s "$@"\n' "$ARCH" > "$WORK/bin/cc-$ARCH"
    printf '#!/bin/sh\nexec clang++ -arch %s "$@"\n' "$ARCH" > "$WORK/bin/cxx-$ARCH"
    chmod +x "$WORK/bin/cc-$ARCH" "$WORK/bin/cxx-$ARCH"

    if [ ! -f "$P/.codecs-done" ]; then
    echo "=== $ARCH: x264"; rm -rf "$B/x264"; cp -R "$SRC/x264" "$B/x264"; (cd "$B/x264"
      CC="$CC" ./configure --prefix="$P" --enable-static --enable-pic --disable-cli --disable-opencl \
        --host="$GNU_HOST" >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)

    echo "=== $ARCH: lame"; rm -rf "$B/lame"; cp -R "$SRC/lame" "$B/lame"; (cd "$B/lame"
      # Its bundled config.sub predates aarch64; Xcode ships none, so take the one automake installs.
      for f in config.sub config.guess; do
        n="$(ls /opt/local/share/automake-*/$f /usr/local/share/automake-*/$f /opt/homebrew/share/automake-*/$f 2>/dev/null | tail -1 || true)"
        [ -n "$n" ] && cp "$n" "$f"
      done
      CC="$CC" ./configure --prefix="$P" --host="$GNU_HOST" --disable-shared --enable-static \
        --disable-frontend --disable-decoder --disable-gtktest >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)

    echo "=== $ARCH: opus"; rm -rf "$B/opus"; mkdir -p "$B/opus"; (cd "$B/opus"
      cmake "$SRC/opus" -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null \
        && cmake --build . -j"$JOBS" >/dev/null && cmake --install . >/dev/null)

    echo "=== $ARCH: libvpx"; rm -rf "$B/libvpx"; mkdir -p "$B/libvpx"; (cd "$B/libvpx"
      "$SRC/libvpx/configure" --prefix="$P" --target="$VPX_TARGET" --enable-pic --enable-vp9-highbitdepth \
        --disable-shared --enable-static --disable-examples --disable-tools --disable-docs --disable-unit-tests \
        >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)

    # x265 is a three-library build (8, 10 and 12 bit) merged into one libx265.a, as every packager does.
    echo "=== $ARCH: x265"; rm -rf "$B/x265"; mkdir -p "$B/x265/8" "$B/x265/10" "$B/x265/12"; (cd "$B/x265"
      local COMMON=(-DCMAKE_C_COMPILER="$WORK/bin/cc-$ARCH" -DCMAKE_CXX_COMPILER="$WORK/bin/cxx-$ARCH" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_PROC" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
      [ "$ARCH" = arm64 ] && [ "$HOST_ARCH" != arm64 ] && COMMON+=(-DCROSS_COMPILE_ARM64=ON)
      local SRCDIR="$SRC/x265_$X265_VER/source"
      (cd 12 && cmake "$SRCDIR" "${COMMON[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DMAIN12=ON >/dev/null && make -j"$JOBS" >/dev/null)
      (cd 10 && cmake "$SRCDIR" "${COMMON[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF >/dev/null && make -j"$JOBS" >/dev/null)
      (cd 8 && ln -sf ../10/libx265.a libx265_main10.a && ln -sf ../12/libx265.a libx265_main12.a
       cmake "$SRCDIR" "${COMMON[@]}" -DEXTRA_LIB="x265_main10.a;x265_main12.a" -DEXTRA_LINK_FLAGS=-L. \
         -DLINKED_10BIT=ON -DLINKED_12BIT=ON -DCMAKE_INSTALL_PREFIX="$P" >/dev/null && make -j"$JOBS" >/dev/null
       mv libx265.a libx265_main.a
       libtool -static -o libx265.a libx265_main.a libx265_main10.a libx265_main12.a
       make install >/dev/null)
      # `make install` copied the unmerged archive; the merged one replaces it.
      cp 8/libx265.a "$P/lib/libx265.a")

    touch "$P/.codecs-done"
    fi

    echo "=== $ARCH: ffmpeg"; rm -rf "$B/ffmpeg"; mkdir -p "$B/ffmpeg"; (cd "$B/ffmpeg"
      # Only our own prefix: a Homebrew/MacPorts codec of the wrong architecture must never be picked up.
      export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig" PKG_CONFIG_PATH=""
      local XC=()
      [ "$ARCH" != "$HOST_ARCH" ] && XC+=(--enable-cross-compile)
      "$SRC/ffmpeg/configure" --prefix="$B/install" --arch="$ARCH" --target-os=darwin ${XC[@]+"${XC[@]}"} \
        --cc="clang -arch $ARCH" --cxx="clang++ -arch $ARCH" \
        --enable-gpl \
        --enable-libx264 --enable-libx265 --enable-libvpx --enable-libmp3lame --enable-libopus \
        --enable-videotoolbox --enable-audiotoolbox \
        --disable-shared --enable-static --disable-doc --disable-ffplay --disable-network \
        --disable-libxcb --disable-xlib --disable-sdl2 --disable-lzma --disable-iconv --disable-securetransport \
        --pkg-config-flags=--static \
        --extra-cflags="-mmacosx-version-min=$MIN_MACOS -I$P/include" \
        --extra-ldflags="-mmacosx-version-min=$MIN_MACOS -L$P/lib" \
        || { tail -50 ffbuild/config.log; exit 1; }
      make -j"$JOBS" ffmpeg ffprobe)
  done

  for t in ffmpeg ffprobe; do
    lipo -create "$WORK/build-arm64/ffmpeg/$t" "$WORK/build-x86_64/ffmpeg/$t" -output "$OUT/$t"
    strip "$OUT/$t" || true
    # Fail here, not on a user's machine: both slices present, and nothing but system libraries linked.
    [ "$(lipo -archs "$OUT/$t" | tr ' ' '\n' | sort | tr '\n' ' ')" = "arm64 x86_64 " ] \
      || { echo "$t is not universal: $(lipo -archs "$OUT/$t")" >&2; exit 1; }
    if otool -L "$OUT/$t" | tail -n +2 | awk '{print $1}' | grep -v -e '^/usr/lib/' -e '^/System/Library/'; then
      echo "$t links a non-system library" >&2; exit 1
    fi
  done
  codesign --force --sign - "$OUT/ffmpeg" "$OUT/ffprobe" 2>/dev/null || true   # ad-hoc: arm64 refuses unsigned code
}

if [ "$(uname -s)" = Darwin ]; then build_darwin; exit 0; fi

git clone --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git src
cd src

EXTRA=()
case "$(uname -s)" in
  MINGW*|MSYS*) EXTE=".exe"; EXTRA+=(--target-os=mingw32 --arch=x86_64)
                # MSYS2 ships both libfoo.a and an import lib libfoo.dll.a for each codec; the linker
                # picks the import lib, giving an ffmpeg.exe that needs libx264-*.dll etc. from
                # mingw64/bin (fine in this shell, "exit 127" on a user's machine). Delete the import
                # libs so only the static archives remain.
                for n in x264 x265 vpx mp3lame opus; do rm -fv "${MINGW_PREFIX:-/mingw64}/lib/lib$n.dll.a"; done
                # Same -lgcc_s problem as Linux below: x265.pc's private libs name it, which pulls in
                # libgcc_s_seh-1.dll despite -static-libgcc. Patched pkg-config copies shadow the originals.
                PCDIR="$WORK/pc"; mkdir -p "$PCDIR"
                for f in "${MINGW_PREFIX:-/mingw64}"/lib/pkgconfig/*.pc; do
                  if [ -f "$f" ]; then sed -E 's/-lgcc_s([[:space:]]|$)/\1/g' "$f" > "$PCDIR/$(basename "$f")"; fi
                done
                export PKG_CONFIG_PATH="$PCDIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ;;
  *)            EXTE="";     EXTRA+=(--disable-network)  # fully static glibc can't resolve hostnames anyway
                # Debian's x265.pc lists -lgcc_s, which doesn't exist for a -static link ("cannot find
                # -lgcc_s"). Use patched copies of the .pc files that drop it.
                PCDIR="$WORK/pc"; mkdir -p "$PCDIR"
                for d in /usr/lib/*/pkgconfig /usr/lib/pkgconfig /usr/share/pkgconfig; do
                  for f in "$d"/*.pc; do
                    if [ -f "$f" ]; then sed 's/-lgcc_s//g' "$f" > "$PCDIR/$(basename "$f")"; fi
                  done
                done
                export PKG_CONFIG_PATH="$PCDIR" ;;
esac

./configure \
  --prefix="$WORK/install" \
  --enable-gpl \
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libmp3lame --enable-libopus \
  --disable-shared --enable-static \
  --disable-doc --disable-ffplay \
  --pkg-config-flags=--static \
  --extra-ldflags="-static -static-libgcc -static-libstdc++" \
  "${EXTRA[@]}" || { tail -50 ffbuild/config.log; exit 1; }

make -j"$(nproc)"

strip "ffmpeg$EXTE" "ffprobe$EXTE" || true
cp "ffmpeg$EXTE" "ffprobe$EXTE" "$OUT/"

# The binaries must not depend on anything but Windows system DLLs (a user's machine has no
# mingw64/bin on PATH).
if [ -n "$EXTE" ]; then
  for t in ffmpeg ffprobe; do
    echo "== $t.exe imports:"; objdump -p "$OUT/$t.exe" | grep "DLL Name" | sort -u
    if objdump -p "$OUT/$t.exe" | grep "DLL Name" | grep -viE "KERNEL32|msvcrt|api-ms-win|ADVAPI32|USER32|GDI32|SHELL32|WS2_32|ole32|OLEAUT32|bcrypt|crypt32|secur32|ncrypt|mfplat|mfuuid|strmiids|Shlwapi|WINMM|imm32|comdlg32|psapi|userenv|ntdll|ucrtbase|setupapi|dxgi|d3d|NETAPI32|IPHLPAPI|WINHTTP|mf\.dll|mfreadwrite|^\s*DLL Name: (VERSION|AVICAP32)\.dll"; then
      echo "ERROR: $t.exe depends on non-system DLLs listed above" >&2; exit 1
    fi
  done
fi

# Fail the build rather than ship a binary that can't encode what the app offers.
"$OUT/ffmpeg$EXTE" -hide_banner -encoders | grep -E "libx264|libx265|libvpx" 
"$OUT/ffprobe$EXTE" -version | head -1
