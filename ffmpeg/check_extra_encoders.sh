#!/bin/bash
#
# Checks StarCore/ffmpeg_extra_encoders.txt against a real ffmpeg.
#
# That file lists encoders the Swift tables carry although the Mac that generates them cannot
# build them (NVIDIA NVENC), described by hand.  A hand-written description rots, so CI runs
# this against the Linux and Windows builds, which do have the encoders: every line must name
# an encoder that exists, say the codec it really encodes and what ffmpeg itself calls it, and
# list only pixel formats it really accepts.  A wrong line then fails here, not in a user's export.
#
#   check_extra_encoders.sh <dir containing ffmpeg> [encoders file]
#
# Exits non-zero if any line is wrong.
#

set -u

DIR="${1:?usage: $0 <dir containing ffmpeg>}"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE="" ;; esac
FFMPEG="$DIR/ffmpeg$EXE"
EXTRA="${2:-$(cd "$(dirname "$0")/.." && pwd)/StarCore/ffmpeg_extra_encoders.txt}"

[ -x "$FFMPEG" ] || { echo "no ffmpeg at $FFMPEG" >&2; exit 2; }
[ -f "$EXTRA" ]  || { echo "no $EXTRA" >&2; exit 2; }

ENCODERS="$("$FFMPEG" -hide_banner -encoders 2>/dev/null)"
FAILED=0
CHECKED=0
fail() { FAILED=$((FAILED + 1)); echo "  FAIL  $1 -- $2"; }

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    encoder=$(printf '%s' "$line" | cut -d'|' -f1 | trim)
    codec=$(printf '%s' "$line" | cut -d'|' -f2 | trim)
    description=$(printf '%s' "$line" | cut -d'|' -f3 | trim)
    formats=$(printf '%s' "$line" | cut -d'|' -f4 | trim)
    CHECKED=$((CHECKED + 1))

    row=$(printf '%s\n' "$ENCODERS" | grep -E "^ [VAS][A-Z.]{5} $encoder( |\$)" | head -n 1)
    if [ -z "$row" ]; then
        fail "$encoder" "this ffmpeg has no such encoder"
        continue
    fi

    # `-encoders` ends the row with "(codec <name>)" for an encoder whose name differs
    case "$row" in
        *"(codec $codec)"*) ;;
        *) fail "$encoder" "it does not encode '$codec': $row" ;;
    esac

    help=$("$FFMPEG" -hide_banner -h "encoder=$encoder" 2>&1)
    printed=$(printf '%s\n' "$help" | sed -n 's/^Encoder [^[]*\[\(.*\)\]:.*$/\1/p' | head -n 1)
    if [ "$printed" != "$description" ]; then
        fail "$encoder" "ffmpeg calls it '$printed', the file says '$description'"
    fi

    accepted=$(printf '%s\n' "$help" | sed -n 's/^[[:space:]]*Supported pixel formats:[[:space:]]*//p' | head -n 1)
    for format in $formats; do
        case " $accepted " in
            *" $format "*) ;;
            *) fail "$encoder" "does not accept $format (it accepts: $accepted)" ;;
        esac
    done
    [ "$FAILED" -eq 0 ] && echo "  ok    $encoder  ($formats)"
done < "$EXTRA"

echo
echo "$CHECKED checked, $FAILED wrong"
[ "$FAILED" -eq 0 ] && [ "$CHECKED" -gt 0 ]
