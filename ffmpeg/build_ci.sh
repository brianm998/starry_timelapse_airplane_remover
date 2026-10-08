#!/bin/bash
# Builds static ffmpeg + ffprobe from source for Linux and Windows (MSYS2 MINGW64), for bundling
# into the Star desktop installers. macOS keeps the hand-built binaries in external_binaries/bin
# (see build.sh, which builds shared libs and isn't suitable for bundling).
#
# Usage: ffmpeg/build_ci.sh <output-dir>      (run from anywhere; clones FFmpeg into a temp dir)
#
# GPL build with the codecs StarCore's encoder list exposes on non-Apple platforms (x264/x265/vpx),
# plus mp3lame/opus. No --enable-nonfree / fdk-aac: the result is redistributable.
set -euo pipefail

OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
FFMPEG_TAG="${FFMPEG_TAG:-n7.1.1}"
WORK="$(mktemp -d)"
cd "$WORK"

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
