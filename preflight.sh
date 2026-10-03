#!/bin/bash

#
# Prerequisite checks, sourced by start_development.sh and gui/local_release.sh.
#
# Usage: source this file, call the preflight_* checks the script needs, then
# call preflight_finish.  Every check runs before anything is reported, so a
# fresh machine learns everything it is missing at once instead of one failed
# build at a time.
#
# Each of these things is missing on a new machine and none of them fails
# anywhere near the cause: Eigen shows up as "'Eigen/Dense' file not found" in a
# .cpp file, the release decision trees as "Unable to resolve module dependency:
# 'StarDecisionTrees'", and the video as a single `error:` line somewhere in
# ~2000 lines of xcodebuild output.
#

PREFLIGHT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT_PROBLEMS=()

# preflight_fail <what is missing> <how to fix it>
preflight_fail() {
    PREFLIGHT_PROBLEMS+=("$1"$'\n'"       fix: $2")
}

# Eigen is a header-only dependency of StarCpp that no build step fetches; it
# comes from the system.  These are the same paths StarCpp/Package.swift passes
# to the compiler with -I.
preflight_eigen() {
    local dir
    case "$(uname -s)" in
        Darwin)
            for dir in /opt/homebrew/include/eigen3 /usr/local/include/eigen3; do
                [ -f "$dir/Eigen/Dense" ] && return 0
            done
            preflight_fail "Eigen headers not found in /opt/homebrew/include/eigen3 or /usr/local/include/eigen3" \
                           "brew install eigen"
            ;;
        Linux)
            [ -f /usr/include/eigen3/Eigen/Dense ] && return 0
            preflight_fail "Eigen headers not found in /usr/include/eigen3" \
                           "sudo apt-get install libeigen3-dev"
            ;;
    esac
    return 0
}

# The gui's Release configuration links the release build of StarDecisionTrees,
# which start_development.sh does not make (it builds the debug one).  The
# archive is universal, so the library has to carry both architectures.
preflight_decision_trees_release() {
    local lib="$PREFLIGHT_ROOT/StarDecisionTrees/lib/release/macos/libStarDecisionTrees.a"
    local module="$PREFLIGHT_ROOT/StarDecisionTrees/include/release/macos/StarDecisionTrees.swiftmodule"
    local fix
    fix="(cd $(printf '%q' "$PREFLIGHT_ROOT/StarDecisionTrees") && ./release.sh)"
    fix="$fix"$'\n'"            (a couple of minutes; it regenerates the tracked Sources/StarDecisionTrees/StarDecisionTrees.swift)"

    if [ ! -f "$lib" ] || [ ! -e "$module" ]; then
        preflight_fail "release StarDecisionTrees is not built (looked for StarDecisionTrees/lib/release/macos/libStarDecisionTrees.a and include/release/macos/StarDecisionTrees.swiftmodule)" \
                       "$fix"
        return 0
    fi

    local arch
    for arch in x86_64 arm64; do
        if ! lipo "$lib" -verify_arch "$arch" > /dev/null 2>&1; then
            preflight_fail "StarDecisionTrees/lib/release/macos/libStarDecisionTrees.a has no $arch slice, but the gui archive is universal" \
                           "$fix"
            return 0
        fi
    done
}

# The gui bundles the videos listed in the "videos" group of its Xcode project
# as resources.  gui/videos is gitignored, so a clone does not have them, and a
# missing one fails Xcode's copy step.  Read the names from the project rather
# than listing them here, so this follows the project when a video is swapped.
preflight_gui_videos() {
    local project="$PREFLIGHT_ROOT/gui/star.xcodeproj/project.pbxproj" name
    [ -f "$project" ] || return 0
    while IFS= read -r name; do
        [ -f "$PREFLIGHT_ROOT/gui/videos/$name" ] && continue
        preflight_fail "gui/videos/$name is missing (the gui bundles it; gui/videos is gitignored, so it is not in the repo)" \
                       "copy gui/videos from a machine that has it; in a worktree, symlink gui/videos to the main checkout's copy"
    done < <(sed -nE 's/.*path = "?([^";]*\.mp4)"?;.*/\1/p' "$project" | sort -u)
    return 0
}

# Report everything the checks found and stop the calling script, or return
# quietly if all was well.
preflight_finish() {
    [ "${#PREFLIGHT_PROBLEMS[@]}" -eq 0 ] && return 0

    local n=${#PREFLIGHT_PROBLEMS[@]} i=1 problem
    {
        echo
        echo "==> $(basename "$0"): $n missing prerequisite(s), stopping before anything is built"
        for problem in "${PREFLIGHT_PROBLEMS[@]}"; do
            echo
            echo "  $i. $problem"
            i=$((i + 1))
        done
        echo
    } >&2
    exit 1
}
