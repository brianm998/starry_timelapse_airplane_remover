#!/bin/bash
#
# Builds the ffmpeg and ffprobe star ships: static, GPL, with hardware acceleration enabled.
# See ffmpeg/README.md for what is in them and why.
#
#   ./build.sh [options] [target]
#
# target is one of: macos-arm64 macos-x64 macos-universal linux-x64 linux-arm64 windows-x64
# and defaults to this machine's native one (macos-universal on a Mac).  A target builds only on
# a machine of its own OS; the macOS slices are the exception, an arm64 Mac builds both.
#
# The special target `tables` builds this machine's native FFmpeg with every GPU encoder star's
# Render Video dialog can offer, and installs it, libraries and headers included, for
# StarCore/regenerate_ffmpeg_tables.sh.  It is a development tool, not something that ships.
#
#   --out DIR     where the finished binaries go (default: ffmpeg/dist), as DIR/<target>/
#   --work DIR    sources, per-target build trees and logs (default: ffmpeg/.work)
#   --install     also copy the result into <repo>/external_binaries/bin, which is where the
#                 Xcode project, the StarCore table generators and star-desktop's gradle
#                 staging all look for ffmpeg/ffprobe
#   --jobs N      parallel make jobs (default: every core)
#   --verbose     stream the build logs instead of keeping them in files
#
# Environment:
#   FFMPEG_BUILD_PATH   directories to put first on PATH, for build tools (nasm, pkg-config,
#                       meson, ninja) that are not installed system-wide
#

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck source=versions.env
. "$HERE/versions.env"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/targets.sh
. "$HERE/lib/targets.sh"
# shellcheck source=lib/deps.sh
. "$HERE/lib/deps.sh"

WORK="$HERE/.work"
OUT="$HERE/dist"
INSTALL=0
JOBS="$(cpu_count)"
REQUESTED=""

usage() { sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --out)     OUT="$2"; shift 2 ;;
        --work)    WORK="$2"; shift 2 ;;
        --jobs)    JOBS="$2"; shift 2 ;;
        --install) INSTALL=1; shift ;;
        --verbose) export FFMPEG_BUILD_VERBOSE=1; shift ;;
        -h|--help) usage 0 ;;
        -*)        echo "unknown option: $1" >&2; usage 1 ;;
        *)         [ -z "$REQUESTED" ] || die "only one target at a time"; REQUESTED="$1"; shift ;;
    esac
done

detect_host
[ -z "${FFMPEG_BUILD_PATH:-}" ] || export PATH="$FFMPEG_BUILD_PATH:$PATH"

if [ -z "$REQUESTED" ]; then
    if [ "$HOST_OS" = macos ]; then REQUESTED=macos-universal; else REQUESTED="$HOST_OS-$HOST_ARCH"; fi
fi

mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
SRC_DIR="$WORK/src"
LOG_DIR="$WORK/logs"
# the tables target installs into the work directory and produces nothing to collect
if [ "$REQUESTED" != tables ]; then
    mkdir -p "$OUT"
    OUT="$(cd "$OUT" && pwd)"
fi

# ── prerequisites ────────────────────────────────────────────────────────────

preflight() {
    local hint
    case "$HOST_OS" in
        macos)   hint="brew install nasm pkgconf meson ninja cmake" ;;
        linux)   hint="sudo apt-get install build-essential nasm pkg-config cmake meson ninja-build git curl xz-utils" ;;
        windows) hint="in an MSYS2 MINGW64 shell: pacman -S base-devel git curl xz diffutils mingw-w64-x86_64-toolchain mingw-w64-x86_64-nasm mingw-w64-x86_64-cmake mingw-w64-x86_64-ninja mingw-w64-x86_64-meson mingw-w64-x86_64-pkgconf" ;;
    esac
    need_cmd git   "$hint"
    need_cmd curl  "$hint"
    need_cmd make  "$hint"
    need_cmd cmake "$hint"
    need_cmd meson "$hint"
    need_cmd ninja "$hint"
    command -v pkg-config >/dev/null 2>&1 || command -v pkgconf >/dev/null 2>&1 \
        || die "pkg-config (or pkgconf) not found in PATH. $hint"
    # nasm assembles the x86 SIMD in x264, x265, dav1d, SVT-AV1, libvpx and FFmpeg; without it
    # they fall back to C and the encoder is several times slower.  Only x64 targets need it.
    local want_nasm=0
    case "$REQUESTED" in
        *x64|macos-universal) want_nasm=1 ;;
        tables)               [ "$HOST_ARCH" = x64 ] && want_nasm=1 ;;
    esac
    if [ "$want_nasm" = 1 ]; then need_cmd nasm "$hint"; fi
}

# ── one target ───────────────────────────────────────────────────────────────

# The libraries FFmpeg links, and the steps that stamp them (the ones the ffmpeg step depends on).
build_dependencies() {
    run_step x264   build_x264   "$X264_COMMIT"
    run_step x265   build_x265   "$X265_SHA256"
    run_step dav1d  build_dav1d  "$DAV1D_SHA256"
    run_step svtav1 build_svtav1 "$SVTAV1_COMMIT"
    run_step libvpx build_libvpx "$LIBVPX_COMMIT"
    DEP_STEPS="x264 x265 dav1d svtav1 libvpx"

    # the GPU headers this target's FFmpeg is configured with (see targets.sh)
    case "$T_OS" in
        linux|windows)
            run_step nvcodec build_nvcodec_headers "$NVCODEC_COMMIT"
            run_step vulkan  build_vulkan_headers  "$VULKAN_HEADERS_COMMIT"
            DEP_STEPS="$DEP_STEPS nvcodec vulkan"
            ;;
    esac
    if [ "$T_OS" = windows ]; then
        run_step amf build_amf_headers "$AMF_COMMIT"
        DEP_STEPS="$DEP_STEPS amf"
    fi
}

build_target() {
    set_target "$1"
    log "target $TARGET  (host $HOST_OS-$HOST_ARCH, $JOBS jobs)"
    log "work:   $WORK/$TARGET"

    build_dependencies
    # its own prefix, so that FFmpeg's installed headers never sit on the include path of the
    # next FFmpeg build (an upgrade would otherwise compile against the old version's)
    FFMPEG_PREFIX="$PREFIX-ffmpeg"
    FFMPEG_BUILD=ffmpeg
    run_step ffmpeg build_ffmpeg "$FFMPEG_SHA256" "$(stamps_digest $DEP_STEPS)" "${FFMPEG_ARGS[*]}"

    package_target
}

# The "tables" target: the native build plus AMD's AMF encoders, which compile anywhere, so that
# one machine can list nearly every encoder star's dialog offers on any platform.  (NVENC cannot:
# FFmpeg's configure refuses to enable it off Linux and Windows, so StarCore's
# ffmpeg_extra_encoders.txt supplies those.)  Installed beside the dependency prefix, and the
# libraries and headers it leaves are what StarCore's muxer table generator links against.
build_tables() {
    set_target "$HOST_OS-$HOST_ARCH"
    log "target tables ($TARGET + AMF)"

    build_dependencies
    run_step amf build_amf_headers "$AMF_COMMIT"

    FFMPEG_PREFIX="$PREFIX-tables"
    FFMPEG_BUILD=ffmpeg-tables
    FFMPEG_ARGS+=(--enable-amf)
    run_step ffmpeg-tables build_ffmpeg "$FFMPEG_SHA256" "$(stamps_digest $DEP_STEPS amf)" "${FFMPEG_ARGS[*]}"

    log "tables FFmpeg: $FFMPEG_PREFIX"
    log "dependency pkg-config files: $PREFIX/lib/pkgconfig"
}

# strip_and_sign <file>
strip_and_sign() {
    case "$T_OS" in
        macos)
            strip -x "$1"
            # Stripping and lipo both invalidate the signature, and an arm64 binary with no
            # valid signature is killed on launch.  Ad hoc is enough to run it locally; the app
            # build re-signs it with the Developer ID.
            codesign --force --sign - "$1"
            ;;
        linux)   strip --strip-unneeded "$1" ;;
        windows) strip --strip-all "$1" ;;
    esac
}

package_target() {
    local dest="$OUT/$TARGET" tool
    rm -rf "$dest"
    mkdir -p "$dest"
    for tool in ffmpeg ffprobe; do
        cp "$FFMPEG_PREFIX/bin/$tool$T_EXE" "$dest/$tool$T_EXE"
        strip_and_sign "$dest/$tool$T_EXE"
    done
    write_license_files "$dest" "$BUILD_DIR/ffmpeg/config.h"
    log "built $dest"
}

write_license_files() { # <dest> <config.h>
    local dest=$1 config_h=$2
    cp "$SRC_DIR/ffmpeg/COPYING.GPLv2" "$dest/LICENSE-ffmpeg.txt"
    {
        echo "FFmpeg $FFMPEG_VERSION, built for $TARGET by star's ffmpeg/build.sh"
        echo
        echo "configuration:"
        # the paths of the machine it was built on mean nothing to a reader
        sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/  \1/p' "$config_h" | sed "s|$WORK|<work>|g"
        echo
        echo "This binary is licensed under the GNU GPL (see LICENSE-ffmpeg.txt) because it"
        echo "contains x264 and x265.  The complete corresponding source is public:"
        echo "  FFmpeg      $FFMPEG_VERSION   $FFMPEG_URL"
        echo "  x264        $X264_COMMIT   $X264_URL"
        echo "  x265        $X265_VERSION   $X265_URL"
        echo "  dav1d       $DAV1D_VERSION   $DAV1D_URL"
        echo "  SVT-AV1     $SVTAV1_VERSION   $SVTAV1_URL @ $SVTAV1_COMMIT"
        echo "  libvpx      $LIBVPX_VERSION   $LIBVPX_URL @ $LIBVPX_COMMIT"
        echo "and the build recipe is ffmpeg/ in https://github.com/brianm998/starry_timelapse_airplane_remover"
    } > "$dest/BUILDINFO.txt"
}

# ── macOS universal: arm64 + x64 slices, joined ──────────────────────────────

build_universal() {
    build_target macos-arm64
    build_target macos-x64

    local dest="$OUT/macos-universal" tool
    rm -rf "$dest"
    mkdir -p "$dest"
    for tool in ffmpeg ffprobe; do
        lipo -create "$OUT/macos-arm64/$tool" "$OUT/macos-x64/$tool" -output "$dest/$tool"
        codesign --force --sign - "$dest/$tool"
        log "$tool: $(lipo -archs "$dest/$tool")"
    done
    cp "$OUT/macos-arm64/LICENSE-ffmpeg.txt" "$dest/"
    # the slices are built alike, so one description covers both; only the heading differs
    sed '1s/built for macos-arm64/built for macos-universal (an arm64 and an x86_64 slice)/' \
        "$OUT/macos-arm64/BUILDINFO.txt" > "$dest/BUILDINFO.txt"
    log "built $dest"
}

# ── go ───────────────────────────────────────────────────────────────────────

preflight

case "$REQUESTED" in
    macos-universal)
        [ "$HOST_OS" = macos ] || die "macos-universal can only be built on a Mac"
        build_universal
        ;;
    tables)
        build_tables
        exit 0
        ;;
    *)
        build_target "$REQUESTED"
        ;;
esac

if [ "$INSTALL" = 1 ]; then
    dest="$REPO_ROOT/external_binaries/bin"
    mkdir -p "$dest"
    cp "$OUT/$REQUESTED"/* "$dest/"
    log "installed into $dest"
fi
