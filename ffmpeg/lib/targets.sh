#!/bin/bash
#
# Per-target toolchain and FFmpeg configure flags for ffmpeg/build.sh.  Sourced.
#
# A "target" is <os>-<arch> with arch one of arm64 / x64 (the naming star-desktop's gradle
# build already uses for app-resources/).  Only macOS builds across architectures (an arm64
# host building the x64 slice, which lipo then joins into a universal binary); Linux and
# Windows are built natively on a runner of the matching architecture.
#

TARGETS="macos-arm64 macos-x64 macos-universal linux-x64 linux-arm64 windows-x64 windows-arm64"

# set_target <target>
#
# Derives the T_* variables, exports the compiler environment, and fills:
#   CMAKE_COMMON      arguments every cmake-built dependency gets
#   MESON_COMMON      arguments for `meson setup`
#   FFMPEG_ARGS       the full ./configure argument list for FFmpeg
set_target() {
    TARGET=$1
    case "$TARGET" in
        macos-arm64)   T_OS=macos;   T_ARCH=arm64; T_FF_ARCH=aarch64 ;;
        macos-x64)     T_OS=macos;   T_ARCH=x64;   T_FF_ARCH=x86_64  ;;
        linux-x64)     T_OS=linux;   T_ARCH=x64;   T_FF_ARCH=x86_64  ;;
        linux-arm64)   T_OS=linux;   T_ARCH=arm64; T_FF_ARCH=aarch64 ;;
        windows-x64)   T_OS=windows; T_ARCH=x64;   T_FF_ARCH=x86_64  ;;
        windows-arm64) T_OS=windows; T_ARCH=arm64; T_FF_ARCH=aarch64 ;;
        *) die "unknown target '$TARGET' (one of: $TARGETS)" ;;
    esac

    [ "$T_OS" = "$HOST_OS" ] || die "cannot build $TARGET on a $HOST_OS host; run this on a $T_OS machine"
    T_CROSS=0
    if [ "$T_ARCH" != "$HOST_ARCH" ]; then
        [ "$T_OS" = macos ] || die "cannot build $TARGET on a $HOST_ARCH host; use a native $T_ARCH runner"
        T_CROSS=1
    fi
    T_EXE=""
    [ "$T_OS" = windows ] && T_EXE=.exe

    # per-dependency target settings; the target_* functions below fill in what applies
    T_X264_HOST_ARGS=()
    T_VPX_TARGET=""
    T_MESON_CROSS=""

    PREFIX="$WORK/$TARGET/prefix"
    BUILD_DIR="$WORK/$TARGET/build"
    mkdir -p "$PREFIX" "$BUILD_DIR" "$SRC_DIR" "$LOG_DIR"

    # Never let a package manager's libraries leak in.  pkg-config looks only in our prefix,
    # and FFmpeg is configured with --disable-autodetect, so every optional library in the
    # result is one named below.
    unset PKG_CONFIG_PATH
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR=""

    CMAKE_COMMON=(
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DCMAKE_INSTALL_LIBDIR=lib
        -DBUILD_SHARED_LIBS=OFF
        # cmake 4 refuses projects that still declare an ancient cmake_minimum_required
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    )
    MESON_COMMON=(
        --prefix="$PREFIX"
        --libdir=lib
        --buildtype=release
        --default-library=static
    )

    case "$T_OS" in
        macos)   target_macos ;;
        linux)   target_linux ;;
        windows) target_windows ;;
    esac

    # Everything above that a dependency's build depends on, so changing any of it rebuilds
    # them (the stamps in common.sh hash this along with each recipe's text).
    T_ENV_KEY="$TARGET|CC=${CC:-}|CXX=${CXX:-}|CFLAGS=${CFLAGS:-}|LDFLAGS=${LDFLAGS:-}"
    T_ENV_KEY="$T_ENV_KEY|cmake=${CMAKE_COMMON[*]}|meson=${MESON_COMMON[*]}|vpx=$T_VPX_TARGET"
    T_ENV_KEY="$T_ENV_KEY|x264=${T_X264_HOST_ARGS[*]:-}|$(${CC_VERSION_CMD:-true} 2>&1 | head -n 1)"
}

# ── flags every target shares ────────────────────────────────────────────────

# The software codecs.  Each is a static library in $PREFIX, found through pkg-config.
ffmpeg_common_args() {
    FFMPEG_ARGS=(
        --extra-version=star
        --pkg-config-flags=--static
        --disable-autodetect
        --enable-static --disable-shared
        --enable-gpl
        --disable-doc --disable-ffplay --disable-debug
        # No capture or playback devices: star only reads and writes files.  lavfi stays,
        # because `-f lavfi -i testsrc2` is how this build is smoke-tested.
        --disable-indevs --enable-indev=lavfi --disable-outdevs
        --enable-zlib
        --enable-libx264 --enable-libx265
        --enable-libdav1d --enable-libsvtav1
        --enable-libvpx
    )
}

# ── macOS ────────────────────────────────────────────────────────────────────
#
# Hardware: VideoToolbox is the media engine on Apple silicon (h264/hevc/prores encode,
# h264/hevc/vp9/av1/prores decode) and the T2/GPU path on Intel Macs.  It, and AudioToolbox,
# are system frameworks, so nothing extra is linked in.
#
# Metal is left out: --enable-metal needs Apple's separate Metal Toolchain download (Xcode 26
# no longer ships it), which a fresh machine or CI runner does not have, and all it adds is a
# few compute-shader filters such as yadif_videotoolbox that star never uses.
target_macos() {
    local clang_arch
    case "$T_ARCH" in arm64) clang_arch=arm64 ;; x64) clang_arch=x86_64 ;; esac

    export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
    export CC="clang -arch $clang_arch"
    export CXX="clang++ -arch $clang_arch"
    export CFLAGS="-O2 -mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET"
    CC_VERSION_CMD="clang --version"

    CMAKE_COMMON+=(
        -DCMAKE_OSX_ARCHITECTURES="$clang_arch"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
        -DCMAKE_SYSTEM_PROCESSOR="$T_FF_ARCH"
    )

    # How each dependency's own build system names this target.
    # libvpx spells the architectures arm64 / x86_64, and wants a darwin version it knows
    # (20 is macOS 11, the floor; the number only picks default flags)
    T_VPX_TARGET="$clang_arch-darwin20-gcc"
    if [ "$T_CROSS" = 1 ]; then
        T_X264_HOST_ARGS=(--host="$T_FF_ARCH-apple-darwin")
        T_MESON_CROSS="$BUILD_DIR/meson-cross.ini"
        cat > "$T_MESON_CROSS" <<EOF
[binaries]
c = ['clang', '-arch', '$clang_arch']
cpp = ['clang++', '-arch', '$clang_arch']
ar = 'ar'
strip = 'strip'

[built-in options]
c_args = ['-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET']
cpp_args = ['-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET']
c_link_args = ['-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET']
cpp_link_args = ['-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET']

[host_machine]
system = 'darwin'
cpu_family = '$T_FF_ARCH'
cpu = '$T_FF_ARCH'
endian = 'little'
EOF
    fi

    ffmpeg_common_args
    FFMPEG_ARGS+=(
        --arch="$T_FF_ARCH"
        --cc="$CC"
        --extra-cflags="-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET -I$PREFIX/include"
        --extra-ldflags="-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET -L$PREFIX/lib"
        --enable-videotoolbox --enable-audiotoolbox
    )
    if [ "$T_CROSS" = 1 ]; then
        FFMPEG_ARGS+=(--enable-cross-compile --target-os=darwin)
    fi
    if [ "$T_ARCH" = x64 ]; then
        FFMPEG_ARGS+=(--x86asmexe=nasm)
    fi
}

# ── GPU APIs shared by Linux and Windows ─────────────────────────────────────
#
# NVIDIA NVENC / NVDEC / CUVID and Vulkan video.  FFmpeg opens the vendor's libraries at run
# time, so on a machine without the hardware these are simply absent, not a missing dependency.
ffmpeg_gpu_args() {
    FFMPEG_ARGS+=(
        --enable-ffnvcodec --enable-nvenc --enable-nvdec --enable-cuvid
        --enable-vulkan
    )
}

# ── Linux ────────────────────────────────────────────────────────────────────
#
# Hardware: NVENC/NVDEC (NVIDIA) and Vulkan video (NVIDIA, AMD, Intel).  VAAPI is left out on
# purpose.  FFmpeg links libva at build time rather than loading it, so a binary that includes
# it will not even start on a machine without libva (a headless server, a minimal container),
# and statically linking libva breaks its driver lookup; that is why static ffmpeg builds
# conventionally omit it.  star does not drive VAAPI encoders yet (they need a device and an
# upload filter), so nothing is lost; a machine that wants VAAPI can point STAR_FFMPEG_DIR at
# its distribution's ffmpeg.
target_linux() {
    local vpx_arch
    case "$T_ARCH" in x64) vpx_arch=x86_64 ;; arm64) vpx_arch=arm64 ;; esac

    export CC=gcc CXX=g++
    export CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC"
    CC_VERSION_CMD="gcc --version"

    CMAKE_COMMON+=(-DCMAKE_POSITION_INDEPENDENT_CODE=ON)
    T_VPX_TARGET="$vpx_arch-linux-gcc"

    ffmpeg_common_args
    FFMPEG_ARGS+=(
        --arch="$T_FF_ARCH" --enable-pic
        --extra-cflags="-I$PREFIX/include"
        # libgcc and libstdc++ come from the archive, so the binary needs only glibc
        --extra-ldflags="-L$PREFIX/lib -static-libgcc"
    )
    ffmpeg_gpu_args
}

# ── Windows ──────────────────────────────────────────────────────────────────
#
# Built in an MSYS2 MINGW64 shell with gcc, linked fully static so that ffmpeg.exe needs
# nothing beyond what Windows itself has.  Hardware: Direct3D 11 / DXVA2 / Direct3D 12 decode,
# Media Foundation encode (the vendor-neutral path: it reaches whichever GPU's encoder the
# driver registers), NVENC/NVDEC, AMD AMF and Vulkan.
#
# Intel Quick Sync (libvpl) is not built: Media Foundation reaches Intel's encoder too, and the
# libvpl dispatcher is one more C++ dependency to keep working under MinGW.
#
# Windows on Arm runs the x64 build under emulation.  A native arm64 build wants a clang
# toolchain and separate asm support in x264/x265/libvpx, and star has no arm64 Windows build
# to bundle it with yet.
target_windows() {
    [ "$T_ARCH" = x64 ] || die "windows-arm64 is not built: Windows on Arm runs the windows-x64 binaries"

    export CC=gcc CXX=g++
    export CFLAGS="-O2" CXXFLAGS="-O2"
    CC_VERSION_CMD="gcc --version"

    CMAKE_COMMON+=(-G Ninja)
    T_VPX_TARGET="x86_64-win64-gcc"

    ffmpeg_common_args
    FFMPEG_ARGS+=(
        --arch=x86_64 --target-os=mingw32
        --extra-cflags="-I$PREFIX/include"
        --extra-ldflags="-L$PREFIX/lib -static -static-libgcc -static-libstdc++"
        --enable-d3d11va --enable-d3d12va --enable-dxva2
        --enable-mediafoundation
        --enable-amf
    )
    ffmpeg_gpu_args
}
