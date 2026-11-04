#!/usr/bin/env bash
# Makes the processed sequence the outlier-group @ui features start from, once, with the cli, and prints where it is.
#
#   gherkin/ui/make-processed-fixture.sh <sequence dir>
#
# A feature that processed the sequence itself would take 100 s on the desktop and 12 minutes in the gui, so the runners ask for this instead
# (`a processed copy of the sequence {sequence}`) and take a relocated copy of it: the cli runs selective over the sequence (no horizon, a static
# camera: what the features need is frames with outlier groups that have decisions), and what it leaves is
#
#   <fixture>/input/<name>                the frames
#   <fixture>/input/star_temp_<name>      its working files, config.json among them (what the app opens)
#   <fixture>/output                      the processed frames
#
# The fixture is kept under STAR_UI_FIXTURES (default <repo>/.test-data/ui-processed), in a directory named for the sequence and for the cli that made
# it, so a new build of the cli makes a new one and a second feature of the same run finds the first's. The cli is STAR_CLI_PATH, else the release
# build in cli/.build; with STAR_CLI_BUILD=1 a missing one is built first (swift build -c release --package-path cli), which takes a while.

set -eu

if [ $# -ne 1 ]; then
    echo "usage: $0 <sequence dir>" >&2
    exit 2
fi
sequence=$(cd "$1" && pwd)
root=$(cd "$(dirname "$0")/../.." && pwd)
star=${STAR_CLI_PATH:-$root/cli/.build/release/star}

if [ ! -x "$star" ] && [ "${STAR_CLI_BUILD:-}" = "1" ]; then
    swift build -c release --package-path "$root/cli" >&2
fi
if [ ! -x "$star" ]; then
    echo "no star cli at $star: build it with 'swift build -c release --package-path cli', or set STAR_CLI_PATH (or STAR_CLI_BUILD=1 to have this build it)" >&2
    exit 2
fi

name=$(basename "$sequence")
# GNU stat first: its -f means "filesystem status" and succeeds, so trying BSD's -f first never reached the fallback on Linux or Windows
stamp=$(stat -c '%Y-%s' "$star" 2>/dev/null || stat -f '%m-%z' "$star")
fixtures=${STAR_UI_FIXTURES:-$root/.test-data/ui-processed}
dest="$fixtures/$name-$stamp"

# What is printed, and handed to the cli, is the path in the form the runner's own language reads: on Windows (Git Bash) a JVM wants C:/..., not /d/a/...
shown=$dest
if command -v cygpath >/dev/null 2>&1; then shown=$(cygpath -m "$dest"); fi

if [ -f "$dest/READY" ]; then
    echo "$shown"
    exit 0
fi

# Made in place, not moved afterwards: the config.json the cli writes holds absolute paths, and the runners relocate a copy by replacing this one.
rm -rf "$dest"
mkdir -p "$dest/input"
cp -R "$sequence" "$dest/input/$name"
if ! "$star" --language en -l info --keep-temp-files --no-horizon -c selective "$shown/input/$name" "$shown/output" > "$dest/star.log" 2>&1; then
    echo "star exited with an error; last output:" >&2
    tail -40 "$dest/star.log" >&2
    rm -rf "$dest"
    exit 1
fi
if [ ! -f "$dest/input/star_temp_$name/config.json" ]; then
    echo "star left no config.json in $dest/input/star_temp_$name" >&2
    rm -rf "$dest"
    exit 1
fi
# What the features start from is frames with outlier groups on disk (frame 0's among them). A cli that ran to the end without writing them
# would leave every feature waiting on a table that never fills, so say so here, with the cli's own log, rather than 90 s into each feature.
outliers="$dest/input/star_temp_$name/outliers"
if [ ! -s "$outliers/0/outliers.bin" ]; then
    echo "star finished but wrote no outlier groups for frame 0 ($outliers/0/outliers.bin); outliers dir:" >&2
    ls -la "$outliers" "$outliers/0" >&2 2>&1 || true
    echo "last output of star:" >&2
    tail -60 "$dest/star.log" >&2
    rm -rf "$dest"
    exit 1
fi
echo "fixture: $(ls "$outliers" | wc -l | tr -d ' ') frames with outlier files, frame 0's outliers.bin is $(wc -c < "$outliers/0/outliers.bin" | tr -d ' ') bytes" >&2
date -u +%Y-%m-%dT%H:%M:%SZ > "$dest/READY"
echo "$shown"
