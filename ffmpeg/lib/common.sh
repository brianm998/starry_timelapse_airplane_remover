#!/bin/bash
#
# Shared helpers for ffmpeg/build.sh.  Sourced, never run directly.
#
# Written for bash 3.2, which is what macOS ships as /bin/bash: no associative arrays, no
# mapfile, and an empty array must be expanded as ${arr[@]+"${arr[@]}"} under `set -u`.
#

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# need_cmd <command> <how to get it>
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH. $2"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

detect_host() {
    case "$(uname -s)" in
        Darwin)               HOST_OS=macos ;;
        Linux)                HOST_OS=linux ;;
        MINGW*|MSYS*|CYGWIN*) HOST_OS=windows ;;
        *) die "unsupported host OS: $(uname -s)" ;;
    esac
    case "$(uname -m)" in
        arm64|aarch64)  HOST_ARCH=arm64 ;;
        x86_64|amd64)   HOST_ARCH=x64 ;;
        *) die "unsupported host architecture: $(uname -m)" ;;
    esac
}

cpu_count() {
    getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4
}

# fetch_tarball <name> <url> <sha256>
# Downloads (once), verifies, and unpacks into $SRC_DIR/<name> with the top-level directory
# stripped.  A checksum mismatch is fatal: the pins in versions.env are the whole point.
fetch_tarball() {
    local name=$1 url=$2 sha=$3
    local dir="$SRC_DIR/$name" file="$SRC_DIR/${url##*/}"
    [ -f "$dir/.fetched-$sha" ] && return 0

    if [ ! -f "$file" ] || [ "$(sha256_of "$file")" != "$sha" ]; then
        log "downloading $url"
        curl -fL --retry 5 --retry-all-errors --retry-delay 5 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    local got
    got=$(sha256_of "$file")
    [ "$got" = "$sha" ] || die "checksum mismatch for ${file##*/}
       expected $sha
       got      $got
       (if the upstream archive was legitimately re-issued, update versions.env)"

    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xf "$file" -C "$dir" --strip-components=1
    touch "$dir/.fetched-$sha"
}

# fetch_git <name> <url> <commit>
# A shallow fetch of exactly one commit into $SRC_DIR/<name>.
fetch_git() {
    local name=$1 url=$2 commit=$3
    local dir="$SRC_DIR/$name"
    if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then
        return 0
    fi
    log "fetching $name $commit from $url"
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
    git -C "$dir" fetch -q --depth 1 origin "$commit"
    git -C "$dir" checkout -q --detach FETCH_HEAD
    [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "$name: fetched commit is not $commit"
}

# fetch_git_sparse <name> <url> <commit> <path>...
# Like fetch_git, but checks out only the given paths and fetches no other file contents, for
# repositories (AMF) where the part wanted is a few hundred KB of a very large tree.
fetch_git_sparse() {
    local name=$1 url=$2 commit=$3
    shift 3
    local dir="$SRC_DIR/$name"
    if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ] \
       && [ -f "$dir/.sparse-$(printf '%s' "$*" | tr -c 'A-Za-z0-9' _)" ]; then
        return 0
    fi
    log "fetching $name $commit from $url (only: $*)"
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
    git -C "$dir" sparse-checkout init --no-cone
    git -C "$dir" sparse-checkout set "$@"
    git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$commit"
    git -C "$dir" checkout -q --detach FETCH_HEAD
    [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "$name: fetched commit is not $commit"
    touch "$dir/.sparse-$(printf '%s' "$*" | tr -c 'A-Za-z0-9' _)"
}

# run_step <name> <function> [extra stamp input...]
#
# Runs <function> in a subshell with `set -e`, logging to $LOG_DIR, unless the step's stamp in
# $PREFIX/.stamps says it already ran with identical inputs.  The stamp hashes the function's
# own text and the toolchain description, so editing a recipe (or switching target) re-runs
# exactly that step; the extra arguments let a step depend on things that are not in its text
# (a pinned version, the stamps of the steps it consumes).
run_step() {
    local name=$1 fn=$2
    shift 2
    local key stamp="$PREFIX/.stamps/$name" log_file="$LOG_DIR/$TARGET-$name.log"
    key=$( { declare -f "$fn"; printf '%s\n' "$T_ENV_KEY"; [ "$#" -gt 0 ] && printf '%s\n' "$@"; } | sha256_stdin )

    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$key" ]; then
        log "$name: up to date"
        return 0
    fi

    log "$name: building (log: $log_file)"
    mkdir -p "$LOG_DIR" "$PREFIX/.stamps"
    local rc
    set +e
    if [ -n "${FFMPEG_BUILD_VERBOSE:-}" ]; then
        ( set -e; "$fn" ) 2>&1 | tee "$log_file"
        rc=${PIPESTATUS[0]}
    else
        ( set -e; "$fn" ) >"$log_file" 2>&1
        rc=$?
    fi
    set -e
    if [ "$rc" -ne 0 ]; then
        [ -n "${FFMPEG_BUILD_VERBOSE:-}" ] || { echo "---- last 60 lines of $log_file ----" >&2; tail -n 60 "$log_file" >&2; }
        die "$name failed (exit $rc); full log: $log_file"
    fi
    printf '%s\n' "$key" > "$stamp"
}

# stamps_digest <step>...: one hash over the named steps' stamps, for the step that consumes
# them.  Named rather than "everything", so a step that FFmpeg does not use (the headers the
# tables variant adds) cannot make the shipping build look out of date.
stamps_digest() {
    local step
    for step in "$@"; do
        cat "$PREFIX/.stamps/$step" 2>/dev/null || echo "missing:$step"
    done | sha256_stdin
}
