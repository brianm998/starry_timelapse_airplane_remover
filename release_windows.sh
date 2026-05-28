#!/bin/bash

# Builds the star CLI binary for Windows and packages it as a .zip file.
#
# Prerequisites — see windows_start.txt for full setup instructions:
#   - Visual Studio Build Tools 2022 with "Desktop development with C++"
#   - Swift toolchain (https://swift.org/install/windows)
#   - Git for Windows (provides this bash, sed, etc.)
#   - CMake
#   - Strawberry Perl
#   - Eigen3 headers at C:/eigen3
#
# Run this script from Git Bash, not from PowerShell or cmd.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

STAR_VERSION=$(cd "$REPO_ROOT/StarCore" && perl version.pl)
echo "==> Building star CLI v${STAR_VERSION} for Windows"

# ── helpers ───────────────────────────────────────────────────────────────────

# Locate lib.exe from the installed VS Build Tools.
# lib.exe is used to merge multiple .lib files into one (analogous to ar -M on Linux).
find_libexe() {
    local vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    if [ ! -f "$vswhere" ]; then
        echo "ERROR: vswhere.exe not found — install VS Build Tools 2022." >&2
        exit 1
    fi
    local vs_win
    vs_win="$("$vswhere" -latest -products '*' \
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
        -property installationPath 2>/dev/null | tr -d '\r')"
    if [ -z "$vs_win" ]; then
        echo "ERROR: VS Build Tools with C++ workload not found." >&2
        exit 1
    fi
    local vs_bash
    vs_bash="$(cygpath -u "$vs_win")"
    local vctools_ver
    vctools_ver=$(tr -d '\r\n' < "$vs_bash/VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt")
    echo "$vs_bash/VC/Tools/MSVC/$vctools_ver/bin/Hostx64/x64/lib.exe"
}

# ── 1. OpenCV ─────────────────────────────────────────────────────────────────
OPENCV_LIB="$REPO_ROOT/opencv/lib/windows/opencv2.lib"
if [ -f "$OPENCV_LIB" ]; then
    echo "==> OpenCV: already built, skipping"
else
    echo "==> OpenCV: not found, building now (this takes 15-30 min)..."
    cd "$REPO_ROOT/opencv"
    bash build.sh
fi

# ── 2. StarDecisionTrees release static library ───────────────────────────────
DT_LIB="$REPO_ROOT/StarDecisionTrees/lib/release/windows/StarDecisionTrees.lib"
if [ -f "$DT_LIB" ]; then
    echo "==> StarDecisionTrees: already built, skipping"
else
    echo "==> Building StarDecisionTrees release lib..."
    cd "$REPO_ROOT/StarDecisionTrees"
    bash release.sh
    echo "==> StarDecisionTrees: done"
fi

# ── 3. CLI ────────────────────────────────────────────────────────────────────
echo "==> Building star CLI (release configuration)..."
cd "$REPO_ROOT/cli"
# No -static-stdlib on Windows; Swift runtime DLLs are bundled in the zip instead.
swift build -c release

BINARY="$REPO_ROOT/cli/.build/release/star.exe"

echo ""
echo "==> Build complete: $BINARY"

# ── 4. .zip package ───────────────────────────────────────────────────────────
echo "==> Creating .zip package..."

case "$(uname -m)" in
    x86_64)  WIN_ARCH="x64" ;;
    aarch64) WIN_ARCH="arm64" ;;
    *)       WIN_ARCH="$(uname -m)" ;;
esac

PKG_STEM="star_${STAR_VERSION}_windows_${WIN_ARCH}"
PKG_DIR="$REPO_ROOT/cli/.build/${PKG_STEM}"
ZIP_FILE="$REPO_ROOT/cli/.build/${PKG_STEM}.zip"

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

cp "$BINARY" "$PKG_DIR/"

# Bundle Swift runtime DLLs so the binary runs without a Swift installation.
# The DLLs live alongside swift.exe in the toolchain bin directory.
SWIFT_BIN="$(dirname "$(command -v swift.exe 2>/dev/null || command -v swift)")"
echo "==> Bundling Swift runtime DLLs from: $SWIFT_BIN"
DLL_COUNT=0
for dll in \
    "$SWIFT_BIN"/swift*.dll \
    "$SWIFT_BIN"/BlocksRuntime.dll \
    "$SWIFT_BIN"/dispatch.dll \
    "$SWIFT_BIN"/msvcp*.dll \
    "$SWIFT_BIN"/vcruntime*.dll \
    "$SWIFT_BIN"/ucrtbase*.dll; do
    if [ -f "$dll" ]; then
        cp "$dll" "$PKG_DIR/"
        DLL_COUNT=$((DLL_COUNT + 1))
    fi
done
echo "    bundled $DLL_COUNT DLL(s)"

cd "$(dirname "$ZIP_FILE")"
# Prefer `zip` if present (matches Linux/macOS behavior exactly); otherwise
# fall back to PowerShell's Compress-Archive, which ships with every Windows
# install. Git for Windows does NOT include `zip` by default, and neither do
# the GitHub Actions windows-2022 runners, so the fallback is the common path
# for CI. Both forms produce a .zip with `<PKG_STEM>/star.exe` inside.
if command -v zip >/dev/null 2>&1; then
    zip -r "$(basename "$ZIP_FILE")" "$(basename "$PKG_DIR")/"
else
    echo "    zip not found, using PowerShell Compress-Archive"
    # PowerShell needs Windows-style paths; -Force overwrites an existing zip.
    PKG_DIR_WIN="$(cygpath -w "$PKG_DIR")"
    ZIP_FILE_WIN="$(cygpath -w "$ZIP_FILE")"
    powershell.exe -NoProfile -Command \
        "Compress-Archive -Path '$PKG_DIR_WIN' -DestinationPath '$ZIP_FILE_WIN' -Force"
fi

# ── 5. NSIS installer (if makensis is available) ──────────────────────────────
MAKENSIS="$(command -v makensis.exe 2>/dev/null || command -v makensis 2>/dev/null || true)"
SETUP_FILE=""
if [ -n "$MAKENSIS" ]; then
    echo "==> Building NSIS installer..."
    SETUP_FILE="$REPO_ROOT/cli/.build/${PKG_STEM}_setup.exe"
    PKG_DIR_WIN="$(cygpath -w "$PKG_DIR")"
    SETUP_FILE_WIN="$(cygpath -w "$SETUP_FILE")"
    NSI_SCRIPT_WIN="$(cygpath -w "$REPO_ROOT/cli/star_installer.nsi")"
    "$MAKENSIS" \
        "-DSTAR_VERSION=$STAR_VERSION" \
        "-DARCH=$WIN_ARCH" \
        "-DPKG_DIR=$PKG_DIR_WIN" \
        "-DOUTPUT_FILE=$SETUP_FILE_WIN" \
        "$NSI_SCRIPT_WIN"
else
    echo "==> makensis not found — skipping NSIS installer (install NSIS to build it)"
fi

rm -rf "$PKG_DIR"

echo ""
echo "==> Package: $ZIP_FILE"
if [ -n "$SETUP_FILE" ]; then
    echo "==> Installer: $SETUP_FILE"
fi
echo "    Install options:"
echo "      - Run ${PKG_STEM}_setup.exe (adds star to PATH automatically)"
echo "      - Or: unzip $PKG_STEM.zip and add the folder to PATH manually"
