#!/bin/bash
#
# Smoke test for a built ffmpeg/ffprobe pair, run by ffmpeg/build.sh's callers (CI and by hand):
# does it run, does it have what star needs, do the software paths round-trip the way star
# drives them, do the hardware paths work where there is hardware, and does it link only against
# what every machine of that OS has.
#
#   smoke_test.sh [--target <target>] [--hw] <dir containing ffmpeg and ffprobe>
#
#   --target T   also check the binaries really are built for T (architecture, linkage rules)
#   --hw         a hardware encoder that is built in but fails to start is a failure rather than
#                a skip.  Use it on a machine known to have the hardware.
#
# Exits non-zero if anything failed.  Bash 3.2 compatible (macOS /bin/bash) and runs under Git
# Bash on Windows.
#

set -u

TARGET=""
REQUIRE_HW=0
DIR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --hw)     REQUIRE_HW=1; shift ;;
        -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)       echo "unknown option: $1" >&2; exit 2 ;;
        *)        DIR="$1"; shift ;;
    esac
done
[ -n "$DIR" ] || { echo "usage: $0 [--target T] [--hw] DIR" >&2; exit 2; }
# the tests below run from a scratch directory, so the binaries need an absolute path
DIR="$(cd "$DIR" && pwd)" || { echo "no such directory: $DIR" >&2; exit 2; }

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe; HOST_OS=windows ;; Darwin) EXE=""; HOST_OS=macos ;; *) EXE=""; HOST_OS=linux ;; esac
[ -n "$TARGET" ] && TARGET_OS="${TARGET%%-*}" || TARGET_OS="$HOST_OS"

FFMPEG="$DIR/ffmpeg$EXE"
FFPROBE="$DIR/ffprobe$EXE"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/star-ffmpeg-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASSED=0; FAILED=0; SKIPPED=0
pass() { PASSED=$((PASSED + 1));   printf '  PASS  %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1));   printf '  FAIL  %s -- %s\n' "$1" "$2"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  skip  %s -- %s\n' "$1" "$2"; }

# check <name> <command...>: pass if it exits 0, otherwise fail with its last output line.
check() {
    local name=$1 out
    shift
    if out=$("$@" 2>&1); then pass "$name"; else fail "$name" "$(printf '%s' "$out" | tail -n 1)"; fi
}

ff() { "$FFMPEG" -hide_banner -loglevel error -y "$@"; }

echo "== $FFMPEG"
[ -x "$FFMPEG" ]  || { echo "  FAIL  $FFMPEG is missing or not executable"; exit 1; }
[ -x "$FFPROBE" ] || { echo "  FAIL  $FFPROBE is missing or not executable"; exit 1; }

# ── it runs ──────────────────────────────────────────────────────────────────
echo "-- runs"
for tool in "$FFMPEG" "$FFPROBE"; do
    if banner=$("$tool" -hide_banner -version 2>&1 | head -n 1) && case "$banner" in *-star*) true ;; *) false ;; esac; then
        pass "${tool##*/} starts: $banner"
    else
        fail "${tool##*/} starts" "${banner:-no output}"
    fi
done

# ── built for the right machine ──────────────────────────────────────────────
if [ -n "$TARGET" ]; then
    echo "-- architecture ($TARGET)"
    case "$TARGET" in
        macos-arm64)     want="arm64" ;;
        macos-x64)       want="x86_64" ;;
        macos-universal) want="x86_64 arm64" ;;
        *)               want="" ;;
    esac
    for tool in "$FFMPEG" "$FFPROBE"; do
        if [ "$TARGET_OS" = macos ]; then
            have=$(lipo -archs "$tool" 2>&1)
            [ "$have" = "$want" ] && pass "${tool##*/} is $have" || fail "${tool##*/} architectures" "want '$want', have '$have'"
        else
            desc=$(file -b "$tool")
            case "$TARGET" in
                *-x64)   pat='x86-64|x86_64|AMD64' ;;
                *-arm64) pat='aarch64|ARM64|arm64' ;;
            esac
            if printf '%s' "$desc" | grep -q -i -E "$pat"; then pass "${tool##*/} is $TARGET"; else fail "${tool##*/} architecture" "file says: $desc"; fi
        fi
    done
fi

# ── links only against what every machine has ────────────────────────────────
echo "-- linkage"
for tool in "$FFMPEG" "$FFPROBE"; do
    case "$TARGET_OS" in
        macos)
            # library lines start with a tab; a universal binary has a header line per slice too
            bad=$(otool -L "$tool" | awk '/^\t/ {print $1}' | grep -v -E '^(/usr/lib/|/System/Library/)' || true)
            ;;
        linux)
            if [ "$HOST_OS" = linux ]; then
                bad=$(ldd "$tool" 2>&1 | awk '{print $1}' | grep -v -E '^(linux-vdso|linux-gate|/lib.*/ld-linux|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libstdc\+\+\.so|libgcc_s\.so|statically)' || true)
            else
                bad=""
            fi
            ;;
        windows)
            bad=$(objdump -p "$tool" 2>/dev/null | sed -n 's/^.*DLL Name: *//p' | grep -i -E '^(lib|msys|cyg)' || true)
            ;;
    esac
    if [ -z "$bad" ]; then pass "${tool##*/} links only system libraries"; else fail "${tool##*/} linkage" "unexpected: $(printf '%s' "$bad" | tr '\n' ' ')"; fi
done

# ── it has what star needs ───────────────────────────────────────────────────
echo "-- components"
ENCODERS=$("$FFMPEG" -hide_banner -encoders 2>/dev/null)
DECODERS=$("$FFMPEG" -hide_banner -decoders 2>/dev/null)
MUXERS=$("$FFMPEG" -hide_banner -muxers 2>/dev/null)
HWACCELS=$("$FFMPEG" -hide_banner -hwaccels 2>/dev/null)
has() { printf '%s\n' "$1" | grep -q -E "^ [A-Z.]{6} $2( |$)"; }
hasmux() { printf '%s\n' "$1" | grep -q -E "^ +E +$2( |$)"; }
for enc in libx264 libx265 libsvtav1 libvpx-vp9 prores_ks dnxhd ffv1 aac; do
    has "$ENCODERS" "$enc" && pass "encoder $enc" || fail "encoder $enc" "not built in"
done
for dec in h264 hevc prores dnxhd vp9 libdav1d aac; do
    has "$DECODERS" "$dec" && pass "decoder $dec" || fail "decoder $dec" "not built in"
done
for mux in mov mp4 matroska adts image2; do
    hasmux "$MUXERS" "$mux" && pass "muxer $mux" || fail "muxer $mux" "not built in"
done

# Hardware: what this OS's build is supposed to carry (see lib/targets.sh).  Quick Sync (libvpl)
# and VAAPI are left out on purpose, so they are not expected.
case "$TARGET_OS" in
    macos)   want_hwaccels="videotoolbox"
             want_hwenc="h264_videotoolbox hevc_videotoolbox prores_videotoolbox" ;;
    linux)   want_hwaccels="cuda vulkan"
             want_hwenc="h264_nvenc hevc_nvenc av1_nvenc" ;;
    windows) want_hwaccels="cuda d3d11va d3d12va dxva2 vulkan"
             want_hwenc="h264_nvenc hevc_nvenc av1_nvenc h264_amf hevc_amf av1_amf h264_mf hevc_mf" ;;
esac
for h in $want_hwaccels; do
    printf '%s\n' "$HWACCELS" | grep -q -x "$h" && pass "hwaccel $h" || fail "hwaccel $h" "not built in"
done
for e in $want_hwenc; do
    has "$ENCODERS" "$e" && pass "hardware encoder $e is built in" || fail "hardware encoder $e" "not built in"
done

# ── software round trip, driven the way star drives it ───────────────────────
echo "-- software round trip"
cd "$WORK" || exit 1
mkdir frames

# a source video with audio, like a camera file
check "make a source video (libx264 + aac)" \
    ff -f lavfi -i "testsrc2=size=1280x720:rate=24" -f lavfi -i "sine=frequency=440:duration=2" \
       -frames:v 48 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest src.mp4

# decodeVideo(): ffprobe, then frames out as 48-bit TIFFs, audio copied out
check "ffprobe reports 48 frames" sh -c "[ \"\$('$FFPROBE' -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=noprint_wrappers=1:nokey=1 src.mp4)\" = 48 ]"
check "decode to rgb48le TIFFs" ff -i src.mp4 -pix_fmt rgb48le frames/image_%04d.tiff
n=$(ls frames 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = 48 ] && pass "48 TIFF frames written" || fail "TIFF frames" "got $n, want 48"
check "extract audio with -acodec copy" ff -i src.mp4 -vn -acodec copy audio.aac

# the export step: TIFFs (+ audio) back into a video, for the encoders the picker offers
encode() { # <name> <ext> <encoder args...>
    local name=$1 ext=$2
    shift 2
    check "encode $name" ff -framerate 24 -start_number 1 -i frames/image_%04d.tiff -i audio.aac -c:a copy "$@" "out_$name.$ext"
}
encode h264        mp4 -c:v libx264     -pix_fmt yuv420p
encode h264_10bit  mkv -c:v libx264     -pix_fmt yuv420p10le
encode hevc_10bit  mp4 -c:v libx265     -pix_fmt yuv420p10le
encode prores_422  mov -c:v prores_ks   -pix_fmt yuv422p10le
encode prores_4444 mov -c:v prores_ks   -pix_fmt yuva444p10le -profile:v 4444
encode vp9         mkv -c:v libvpx-vp9  -pix_fmt yuv420p -b:v 2M
encode av1         mkv -c:v libsvtav1   -pix_fmt yuv420p10le
encode ffv1        mkv -c:v ffv1        -pix_fmt yuv444p10le
check "encode dnxhd" ff -framerate 24 -start_number 1 -i frames/image_%04d.tiff -vf scale=1920:1080 \
    -c:v dnxhd -b:v 36M -pix_fmt yuv422p out_dnxhd.mov
for f in out_h264.mp4 out_prores_422.mov out_av1.mkv; do
    check "ffprobe reads $f back" sh -c "[ \"\$('$FFPROBE' -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=noprint_wrappers=1:nokey=1 $f)\" = 48 ]"
done
check "decode AV1 with dav1d"  ff -c:v libdav1d -i out_av1.mkv -f null -
check "decode HEVC"            ff -i out_hevc_10bit.mp4 -f null -
check "decode ProRes"          ff -i out_prores_4444.mov -f null -

# ── hardware ─────────────────────────────────────────────────────────────────
echo "-- hardware (a skip means the build has the encoder but this machine has no device for it)"
hw_encode() { # <encoder>
    local e=$1 out
    has "$ENCODERS" "$e" || return 0
    if out=$(ff -f lavfi -i "testsrc2=size=1280x720:rate=24" -frames:v 24 -pix_fmt yuv420p -c:v "$e" -f null - 2>&1); then
        pass "hardware encode with $e"
    elif [ "$REQUIRE_HW" = 1 ]; then
        fail "hardware encode with $e" "$(printf '%s' "$out" | tail -n 1)"
    else
        skip "hardware encode with $e" "$(printf '%s' "$out" | tail -n 1)"
    fi
}
for e in $want_hwenc; do
    hw_encode "$e"
done

# hardware decode: only meaningful on the OS whose accelerator is always there
if [ "$TARGET_OS" = macos ] && [ "$HOST_OS" = macos ]; then
    if out=$(ff -hwaccel videotoolbox -i out_hevc_10bit.mp4 -f null - 2>&1) \
       && ! printf '%s' "$out" | grep -q -i 'failed\|error'; then
        pass "hardware decode with videotoolbox"
    elif [ "$REQUIRE_HW" = 1 ]; then
        fail "hardware decode with videotoolbox" "$(printf '%s' "$out" | tail -n 1)"
    else
        skip "hardware decode with videotoolbox" "$(printf '%s' "$out" | tail -n 1)"
    fi
fi

echo
echo "$PASSED passed, $FAILED failed, $SKIPPED skipped"
[ "$FAILED" -eq 0 ]
