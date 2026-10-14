#!/bin/bash
#
# Recipes for the codec libraries FFmpeg links statically.  Sourced by ffmpeg/build.sh; each
# build_* function runs through run_step in a subshell with `set -e`, in $BUILD_DIR/<name>,
# and installs into $PREFIX.  Everything builds out of tree, so the two macOS slices share one
# unpacked source.
#

# merge_static_libs <out.a> <in.a>...
merge_static_libs() {
    local out=$1
    shift
    rm -f "$out"
    if [ "$T_OS" = macos ]; then
        libtool -static -o "$out" "$@"
    else
        { echo "CREATE $out"; for lib in "$@"; do echo "ADDLIB $lib"; done; echo "SAVE"; echo "END"; } | ar -M
    fi
}

# ── x264: H.264 ──────────────────────────────────────────────────────────────
# --bit-depth=all puts the 8- and 10-bit encoders in one library, so 10-bit H.264 output
# (High 10, which is what a 10-bit timelapse deliverable wants) works as well as 8-bit.
build_x264() {
    fetch_git x264 "$X264_URL" "$X264_COMMIT"
    rm -rf "$BUILD_DIR/x264"
    mkdir -p "$BUILD_DIR/x264"
    cd "$BUILD_DIR/x264"
    "$SRC_DIR/x264/configure" \
        --prefix="$PREFIX" \
        --enable-static --disable-cli --enable-pic \
        --bit-depth=all --disable-opencl \
        ${T_X264_HOST_ARGS[@]+"${T_X264_HOST_ARGS[@]}"}
    make -j"$JOBS"
    make install
}

# ── x265: HEVC ───────────────────────────────────────────────────────────────
# x265 only builds one bit depth per library, so this is the upstream "multilib" recipe: a
# 12-bit and a 10-bit library, then the 8-bit one that links them, merged into one libx265.a.
build_x265() {
    fetch_tarball x265 "$X265_URL" "$X265_SHA256"
    local src="$SRC_DIR/x265/source" b="$BUILD_DIR/x265"
    rm -rf "$b"
    mkdir -p "$b"

    local common=(
        "${CMAKE_COMMON[@]}"
        -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_LIBNUMA=OFF -DENABLE_LIBVMAF=OFF
    )
    cmake -S "$src" -B "$b/12" "${common[@]}" -DHIGH_BIT_DEPTH=ON -DMAIN12=ON -DEXPORT_C_API=OFF
    cmake --build "$b/12" -j "$JOBS"
    cmake -S "$src" -B "$b/10" "${common[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
    cmake --build "$b/10" -j "$JOBS"

    mkdir -p "$b/8"
    ln -sf ../10/libx265.a "$b/8/libx265_main10.a"
    ln -sf ../12/libx265.a "$b/8/libx265_main12.a"
    cmake -S "$src" -B "$b/8" "${common[@]}" \
        -DEXTRA_LIB="x265_main10.a;x265_main12.a" -DEXTRA_LINK_FLAGS=-L. \
        -DLINKED_10BIT=ON -DLINKED_12BIT=ON
    cmake --build "$b/8" -j "$JOBS"

    (
        cd "$b/8"
        mv libx265.a libx265_main.a
        merge_static_libs libx265.a libx265_main.a libx265_main10.a libx265_main12.a
    )
    cmake --install "$b/8"

    # x265 is C++, so its pkg-config file asks for the C++ runtime by name and the linker
    # would pick the shared libstdc++.so, which then has to exist (at this version) on the
    # user's machine.  Point it at the archive instead.  (On macOS libc++ is a system library,
    # and on Windows -static does the same job.)
    # Its private libs also name -lgcc_s (from the compiler's implicit link libraries).  The
    # builds here use the static libgcc, so that pulls the shared one in beside it: on Windows
    # the two define _Unwind_Resume twice and ffmpeg_g.exe does not link, and on Linux the
    # probe that links a test program against x265 fails, so configure says "x265 not found".
    # Same fix as build_ci.sh.
    if [ "$T_OS" = linux ] || [ "$T_OS" = windows ]; then
        sed -i.bak -E 's/-lgcc_s([[:space:]]|$)/\1/g' "$PREFIX/lib/pkgconfig/x265.pc"
        rm -f "$PREFIX/lib/pkgconfig/x265.pc.bak"
    fi
    if [ "$T_OS" = linux ]; then
        local libstdcxx
        libstdcxx=$("${CXX%% *}" -print-file-name=libstdc++.a)
        [ -f "$libstdcxx" ] || { echo "libstdc++.a not found (install the g++ static runtime)"; return 1; }
        sed -i.bak "s|-lstdc++|$libstdcxx|" "$PREFIX/lib/pkgconfig/x265.pc"
        rm -f "$PREFIX/lib/pkgconfig/x265.pc.bak"
    fi
}

# ── dav1d: AV1 decode ────────────────────────────────────────────────────────
build_dav1d() {
    fetch_tarball dav1d "$DAV1D_URL" "$DAV1D_SHA256"
    local b="$BUILD_DIR/dav1d"
    rm -rf "$b"
    meson setup "$b" "$SRC_DIR/dav1d" \
        "${MESON_COMMON[@]}" \
        -Denable_tools=false -Denable_tests=false \
        ${T_MESON_CROSS:+--cross-file="$T_MESON_CROSS"}
    meson compile -C "$b"
    meson install -C "$b"
}

# ── SVT-AV1: AV1 encode ──────────────────────────────────────────────────────
build_svtav1() {
    fetch_git svtav1 "$SVTAV1_URL" "$SVTAV1_COMMIT"
    local b="$BUILD_DIR/svtav1"
    rm -rf "$b"
    cmake -S "$SRC_DIR/svtav1" -B "$b" "${CMAKE_COMMON[@]}" \
        -DBUILD_APPS=OFF -DBUILD_DEC=OFF -DBUILD_TESTING=OFF -DSVT_AV1_LTO=OFF
    cmake --build "$b" -j "$JOBS"
    cmake --install "$b"
}

# ── libvpx: VP8 / VP9 ────────────────────────────────────────────────────────
build_libvpx() {
    fetch_git libvpx "$LIBVPX_URL" "$LIBVPX_COMMIT"
    rm -rf "$BUILD_DIR/libvpx"
    mkdir -p "$BUILD_DIR/libvpx"
    cd "$BUILD_DIR/libvpx"
    "$SRC_DIR/libvpx/configure" \
        --prefix="$PREFIX" --target="$T_VPX_TARGET" \
        --disable-shared --enable-static --enable-pic \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests \
        --disable-install-docs --disable-install-srcs \
        --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth
    make -j"$JOBS"
    make install
}

# ── GPU APIs: headers only ───────────────────────────────────────────────────
# See versions.env: the libraries themselves belong to the GPU driver and are loaded at run
# time, so these install nothing that ends up in the binary but FFmpeg's knowledge of the API.

build_nvcodec_headers() {
    fetch_git nvcodec "$NVCODEC_URL" "$NVCODEC_COMMIT"
    make -C "$SRC_DIR/nvcodec" PREFIX="$PREFIX" install
}

build_amf_headers() {
    fetch_git_sparse amf "$AMF_URL" "$AMF_COMMIT" amf/public/include
    rm -rf "$PREFIX/include/AMF"
    mkdir -p "$PREFIX/include/AMF"
    cp -R "$SRC_DIR/amf/amf/public/include/." "$PREFIX/include/AMF/"
}

build_vulkan_headers() {
    fetch_git vulkan-headers "$VULKAN_HEADERS_URL" "$VULKAN_HEADERS_COMMIT"
    mkdir -p "$PREFIX/include"
    rm -rf "$PREFIX/include/vulkan" "$PREFIX/include/vk_video"
    cp -R "$SRC_DIR/vulkan-headers/include/vulkan" "$SRC_DIR/vulkan-headers/include/vk_video" "$PREFIX/include/"
}

# ── FFmpeg itself ────────────────────────────────────────────────────────────
# Variables, with the defaults the shipping build uses:
#   FFMPEG_PREFIX  where it installs (the dependency prefix)
#   FFMPEG_BUILD   its build directory name under $BUILD_DIR
build_ffmpeg() {
    fetch_tarball ffmpeg "$FFMPEG_URL" "$FFMPEG_SHA256"
    local build="$BUILD_DIR/${FFMPEG_BUILD:-ffmpeg}"
    rm -rf "$build"
    mkdir -p "$build"
    cd "$build"
    "$SRC_DIR/ffmpeg/configure" --prefix="${FFMPEG_PREFIX:-$PREFIX}" "${FFMPEG_ARGS[@]}"
    make -j"$JOBS"
    make install
}
