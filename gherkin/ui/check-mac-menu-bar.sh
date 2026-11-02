#!/usr/bin/env bash
# Looks at the real Mac menu bar of the running desktop client (Kotlin/Compose, star-desktop) and checks it against the menus the app builds.
#
#   gherkin/ui/check-mac-menu-bar.sh [<sequence dir>]        (default: test_data/test_a7sii_10)
#
# The Compose test host has no AWT menu bar, so the @ui features on the desktop work on `starMenus(app)` (StarMenuBar.kt), the menus as data.
# Nothing else has seen what a running app puts in the system's menu bar. This starts the app for each of three states and reads the
# bar through System Events (AppleScript), for the process the app is:
#
#   1  no sequence open      the bar is File, Window, Language: no Actions, no Tools (M12)       FAIL if not
#   2  a sequence open       File, Actions, Tools, Window, Language                              FAIL if not
#   3  the outlier window    Window > Outlier Information Window, then the bar with "Outliers    RECORDED, not failed (M9: the answer is whatever
#      focused               for frame N" the focused window                                      the bar shows; the line says which)
#
# The expected titles are read, not typed here: the catalogue (en.json, the app runs with STAR_LANG=en) by the keys of
# gherkin/ui/commands.json `menus`, and `language.menu` for the Language menu, which is the desktop's own (not a command, so not in commands.json).
# On a Mac the bar starts with the system's Apple menu and the app's own menu (named `java` under gradle); those are reported, not compared.
#
# A sequence is opened with the app's dev argument (Main.kt), so no native file dialog is needed; it is a copy in a temp dir, because opening one
# writes its working files beside it. Each state is a fresh launch of `gradlew run` (which builds stard in release first: slow the first time).
#
# Needs: macOS, a logged-in desktop session, and Accessibility access for whatever runs this (Terminal, or the process that started it:
# System Settings > Privacy & Security > Accessibility). Without any of that it prints `SKIP: <reason>` and exits 0, never a failure.
# Exit: 0 all PASS (or SKIP), 1 a FAIL, 2 usage.
#
# This is a heavy job (gradle, swift build, the app): from this repo run it as `pipeline/bin/starpipe heavy -- gherkin/ui/check-mac-menu-bar.sh`
# (the interactive hook wraps only commands that call gradlew directly, not a script that does).
#
# Tunables: STAR_MENUBAR_TIMEOUT seconds to wait for the app to come up per launch (default 900: the first launch builds stard).

set -eu

skip() { echo "SKIP: $*"; exit 0; }

# ---- guard (A4): every missing prerequisite is a SKIP with the reason, never a failure -------------------------------------------------------

if [ "$(uname -s)" != "Darwin" ]; then
    skip "not macOS ($(uname -s)): the real menu bar is read through System Events, which only a Mac has"
fi
if [ $# -gt 1 ]; then
    echo "usage: $0 [<sequence dir>]" >&2
    exit 2
fi

root=$(cd "$(dirname "$0")/../.." && pwd)
sequence_arg=${1:-$root/test_data/test_a7sii_10}
timeout_s=${STAR_MENUBAR_TIMEOUT:-900}

command -v osascript >/dev/null 2>&1 || skip "osascript is not installed"
command -v python3 >/dev/null 2>&1 || skip "python3 is not installed (it reads the catalogue and commands.json)"
if ! probe=$(osascript -e 'tell application "System Events" to get name of every process' 2>&1); then
    case "$probe" in
        *-25211*|*-1719*|*assistive*|*not\ allowed*|*"not authorized"*|*-1743*)
            skip "System Events access is refused ($(echo "$probe" | head -1)). Grant it: System Settings > Privacy & Security > Accessibility (and Automation > System Events) for the app running this script (Terminal, or the process that launched it), then run it again" ;;
        *)
            skip "System Events cannot be asked ($(echo "$probe" | head -1)); is there a logged-in desktop session? Accessibility access for the app running this is System Settings > Privacy & Security > Accessibility" ;;
    esac
fi
[ -x "$root/star-desktop/gradlew" ] || skip "star-desktop/gradlew is missing, there is no way to launch the app"
if [ ! -x "$root/daemon/.build/release/stard" ] && ! command -v swift >/dev/null 2>&1; then
    skip "there is no stard (daemon/.build/release/stard) and no swift to build one, so the app cannot open a sequence"
fi
[ -d "$sequence_arg" ] || skip "the sequence directory $sequence_arg does not exist"
[ -n "$(find "$sequence_arg" -maxdepth 1 \( -iname '*.jpg' -o -iname '*.tif' -o -iname '*.tiff' \) | head -1)" ] || skip "$sequence_arg has no frames (jpg or tif)"
sequence=$(cd "$sequence_arg" && pwd)
case "$sequence" in *" "*|*"::"*) skip "the sequence path has a space or '::' in it ($sequence), which the dev argument (--args, split on ::) cannot carry" ;; esac

# ---- expected titles, from the catalogue and commands.json -----------------------------------------------------------------------------------

titles=$(python3 -I - "$root" <<'PY'
import json, sys
root = sys.argv[1]
en = json.load(open(root + "/StarCore/Sources/StarCore/Resources/Localizations/en.json", encoding="utf-8"))
menus = json.load(open(root + "/gherkin/ui/commands.json", encoding="utf-8"))["menus"]
out = {k: en[v] for k, v in menus.items()}
out["language"] = en["language.menu"]
out["outlierItem"] = en["ui.outlier_information_window"]
out["outlierWindow"] = en["ui.outliers_for_frame"].replace("{0}", "")
for k, v in out.items():
    print(k + "=" + v)
PY
) || skip "could not read the catalogue or commands.json"
title_of() { echo "$titles" | sed -n "s/^$1=//p"; }
file_t=$(title_of file); actions_t=$(title_of actions); tools_t=$(title_of tools); window_t=$(title_of window); language_t=$(title_of language)
outlier_item=$(title_of outlierItem); outlier_window_prefix=$(title_of outlierWindow)

expect_empty="$file_t|$window_t|$language_t"
expect_open="$file_t|$actions_t|$tools_t|$window_t|$language_t"

# ---- System Events ------------------------------------------------------------------------------------------------------------------------

# bar <pid>: the titles of the bar's items, '|' separated, Apple menu first.
bar() {
    osascript - "$1" <<'AS'
on run argv
    set thePid to (item 1 of argv) as integer
    tell application "System Events"
        set p to first process whose unix id is thePid
        set names to name of every menu bar item of menu bar 1 of p
    end tell
    set AppleScript's text item delimiters to "|"
    set r to ""
    repeat with n in names
        if r is not "" then set r to r & "|"
        set r to r & (n as text)
    end repeat
    return r
end run
AS
}

# window_names <pid>: titles of the process's windows, '|' separated.
window_names() {
    osascript - "$1" <<'AS' 2>/dev/null || true
on run argv
    set thePid to (item 1 of argv) as integer
    tell application "System Events"
        set p to first process whose unix id is thePid
        set names to name of every window of p
    end tell
    set r to ""
    repeat with n in names
        if r is not "" then set r to r & "|"
        set r to r & (n as text)
    end repeat
    return r
end run
AS
}

# focused_window <pid>: the title of the window with the keyboard focus (AXFocusedWindow), empty if none.
focused_window() {
    osascript - "$1" <<'AS' 2>/dev/null || true
on run argv
    set thePid to (item 1 of argv) as integer
    tell application "System Events"
        set p to first process whose unix id is thePid
        return name of (value of attribute "AXFocusedWindow" of p)
    end tell
end run
AS
}

raise() {
    osascript - "$1" <<'AS' >/dev/null 2>&1 || true
on run argv
    tell application "System Events" to set frontmost of (first process whose unix id is ((item 1 of argv) as integer)) to true
end run
AS
}

# click_window_item <pid> <menu title> <item title>
click_item() {
    osascript - "$1" "$2" "$3" <<'AS'
on run argv
    set thePid to (item 1 of argv) as integer
    tell application "System Events"
        set p to first process whose unix id is thePid
        click menu item (item 3 of argv) of menu 1 of menu bar item (item 2 of argv) of menu bar 1 of p
    end tell
end run
AS
}

# ---- launching the app -------------------------------------------------------------------------------------------------------------------

work=$(mktemp -d "${TMPDIR:-/tmp}/star-menubar.XXXXXX")
gradle_pid=""
app_pid=""
log=""
stop_app() {
    if [ -n "$app_pid" ]; then kill "$app_pid" 2>/dev/null || true; fi
    if [ -n "$gradle_pid" ]; then
        kill "$gradle_pid" 2>/dev/null || true
        wait "$gradle_pid" 2>/dev/null || true
    fi
    app_pid=""; gradle_pid=""
}
cleanup() { stop_app; rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

jvm_pids() { pgrep -f 'com\.star\.desktop\.MainKt' 2>/dev/null | sort || true; }

# launch <label> [<arg>]: starts the app, sets app_pid when its JVM has a window; returns 1 (and says why) when it does not come up.
launch() {
    local label=$1 arg=${2:-}
    local before; before=$(jvm_pids)
    log="$work/$label.log"
    if [ -n "$arg" ]; then
        STAR_LANG=en "$root/star-desktop/gradlew" -p "$root/star-desktop" run --args="$arg" >"$log" 2>&1 &
    else
        STAR_LANG=en "$root/star-desktop/gradlew" -p "$root/star-desktop" run >"$log" 2>&1 &
    fi
    gradle_pid=$!
    local waited=0 found=""
    while [ "$waited" -lt "$timeout_s" ]; do
        if ! kill -0 "$gradle_pid" 2>/dev/null; then
            echo "SKIP: $label: gradlew run ended before the app had a window; the end of its output:"; tail -15 "$log" | sed 's/^/    /'
            gradle_pid=""; return 1
        fi
        found=$(comm -13 <(echo "$before") <(jvm_pids) | head -1)
        if [ -n "$found" ]; then
            app_pid=$found
            if [ -n "$(window_names "$app_pid")" ]; then return 0; fi
        fi
        sleep 2; waited=$((waited + 2))
    done
    echo "SKIP: $label: the app had no window after ${timeout_s}s (STAR_MENUBAR_TIMEOUT); the end of gradle's output:"; tail -15 "$log" | sed 's/^/    /'
    stop_app
    return 1
}

# wait_bar <pid> <expected> : polls up to 90 s for the bar to equal what is expected after the system items; sets $actual (full) and $rest.
wait_bar() {
    local pid=$1 expected=$2 waited=0
    while :; do
        actual=$(bar "$pid" 2>/dev/null || true)
        rest=$(echo "$actual" | cut -d'|' -f3-)
        if [ "$rest" = "$expected" ] || [ "$waited" -ge 90 ]; then break; fi
        sleep 2; waited=$((waited + 2))
    done
}

system_items() { echo "$actual" | cut -d'|' -f1-2 | sed 's/|/, /'; }

fail=0
pass_or_fail() { # <state> <expected> <title for the line>
    if [ "$rest" = "$2" ]; then
        echo "PASS: $1: bar is [$rest] (after the system's: $(system_items))"
    else
        echo "FAIL: $1: expected [$2], the real bar has [$actual] (system items are the first two: Apple and the app's)"
        fail=1
    fi
}

# ---- state 1: no sequence (A2) ------------------------------------------------------------------------------------------------------------

echo "== state 1: no sequence open"
if launch empty; then
    raise "$app_pid"; sleep 3
    wait_bar "$app_pid" "$expect_empty"
    pass_or_fail "no sequence" "$expect_empty"
    for gone in "$actions_t" "$tools_t"; do
        case "|$rest|" in *"|$gone|"*) echo "FAIL: no sequence: '$gone' is in the bar"; fail=1 ;; *) echo "PASS: no sequence: '$gone' is not in the bar" ;; esac
    done
    stop_app
else
    exit 0
fi

# ---- state 2: a sequence open (A1, A2), state 3: its outlier window focused (A3) ----------------------------------------------------------------

cp -R "$sequence" "$work/seq"
echo "== state 2: sequence open ($sequence, a copy)"
if launch sequence "$work/seq"; then
    raise "$app_pid"
    wait_bar "$app_pid" "$expect_open"
    pass_or_fail "sequence open" "$expect_open"
    for here in "$actions_t" "$tools_t"; do
        case "|$rest|" in *"|$here|"*) echo "PASS: sequence open: '$here' is in the bar" ;; *) echo "FAIL: sequence open: '$here' is not in the bar"; fail=1 ;; esac
    done

    echo "== state 3: outlier window focused (M9)"
    if click_item "$app_pid" "$window_t" "$outlier_item" >/dev/null 2>"$work/click.err"; then
        waited=0; focused=""
        while [ "$waited" -lt 60 ]; do
            focused=$(focused_window "$app_pid")
            case "$focused" in "$outlier_window_prefix"*) break ;; esac
            sleep 1; waited=$((waited + 1))
        done
        sleep 2
        wait_bar "$app_pid" "$expect_open"
        echo "windows: [$(window_names "$app_pid")]; focused window: [$focused]"
        case "$focused" in
            "$outlier_window_prefix"*)
                if [ "$rest" = "$expect_open" ]; then
                    echo "PASS: outlier window focused: bar is [$rest] (after the system's: $(system_items)): the focused window's menu bar is the app's, same as the main window's"
                else
                    echo "RECORDED (M9): outlier window focused: expected [$expect_open], the real bar has [$actual]"
                fi ;;
            *) echo "RECORDED (M9): the outlier window did not take the focus (focused: [$focused]); the bar is [$actual]" ;;
        esac
    else
        echo "RECORDED (M9): could not open '$outlier_item' from the '$window_t' menu: $(head -1 "$work/click.err")"
    fi
    stop_app
else
    exit 0
fi

if [ "$fail" -eq 0 ]; then echo "PASS: menu bar check done"; else echo "FAIL: menu bar check"; fi
exit "$fail"
