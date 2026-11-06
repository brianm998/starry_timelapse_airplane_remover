#!/bin/bash
# macOS only: does the desktop app's Dock icon bring its main window back after the window was closed?
# (M10 / D10 of plans/GUI_CLIENT_PARITY_PLAN.md.) Runs the packaged app the way a user would:
#
#   1. starts Star.app with no sequence, waits for its main window, reads its title ("Star": the start screen);
#   2. closes the window with its red close button (the user's close: Compose's onCloseRequest ->
#      AppViewModel.requestCloseWindow), and checks the process is still running and none of its windows is on screen;
#   3. sends the reopen event a Dock click sends (`open -a Star.app`) and checks the same process has its main
#      window back, titled "Star".
#
# Usage: packaging/dock-reopen-check.sh <app-image-dir> [work-dir]
#
#   <app-image-dir>  what `gradlew createDistributable` produced (build/compose/binaries/main/app), the directory
#                    holding Star.app. `./gradlew run` is no use: it starts a bare `java` with no bundle, which
#                    `open -a` cannot address.
#   [work-dir]       scratch space (default: a fresh mktemp dir); the app runs with its HOME in here, so the
#                    user's own preferences and recents are neither read nor written
#
# Prints SKIP: <why> and exits 77 where it cannot run (not a Mac, no display or GUI session, no Star.app in the
# image, or System Events will not answer or cannot see the app's window, which means the Automation or
# Accessibility permission it needs to click the close button is missing). Prints a
# PASS line for each of the three states and exits 0; prints FAIL: <what was seen> and exits 1 if the app quits,
# the window will not go, or it does not come back.
#
# Needs: a Mac with a logged-in desktop session, and Automation (to control System Events) and Accessibility
# (System Settings > Privacy & Security) granted to the terminal or runner that runs this. The close button is
# clicked, and the title read, through System Events. No Screen Recording permission is needed: whether a window is
# on screen is read from owner pid, layer and size (CGWindowListCopyWindowInfo gives those without it).
#
# A pass proves the window came back, not which listener brought it: `open -a` also raises the app, so
# AppReopenedListener (the Dock click) and AppForegroundListener (the app coming forward) could each have done it.
set -uo pipefail

skip() { echo "SKIP: $*"; exit 77; }

# --- the guard: skip, never fail, where the check cannot be made -----------------------------------------------
[ $# -ge 1 ] || { echo "usage: $0 <app-image-dir> [work-dir]" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || skip "not a Mac ($(uname -s)): this check needs macOS's Dock and window server"
command -v osascript >/dev/null 2>&1 || skip "osascript is not installed"

# JXA that prints "ok" when this process is in a GUI session that is on the console, with a display; else why not.
# (A session with no GUI has a zero display id and no session dictionary.)
GUARD_JS='
ObjC.import("CoreGraphics");
function run() {
  if ($.CGMainDisplayID() === 0) return "no display";
  var session = null;
  try { session = ObjC.deepUnwrap(ObjC.castRefToObject($.CGSessionCopyCurrentDictionary())); } catch (e) {}
  if (!session || session.kCGSSessionOnConsoleKey !== true) return "no GUI session on the console (nobody logged in there, or this user switched out)";
  return "ok";
}'
GUARD="$(osascript -l JavaScript -e "$GUARD_JS" 2>&1)" || skip "cannot ask the window server: $GUARD"
[ "$GUARD" = ok ] || skip "$GUARD"
# May this terminal or runner talk to System Events? (-1743: the Automation permission was refused or never given.)
PROBE="$(osascript -e 'tell application "System Events" to count of processes' 2>&1)" ||
  skip "System Events does not answer this terminal or runner (grant Automation, and Accessibility): $PROBE"

APP_IMAGE="$(cd "$1" 2>/dev/null && pwd)" || skip "$1 is not a directory"
BUNDLE="$APP_IMAGE/Star.app"
LAUNCHER="$BUNDLE/Contents/MacOS/Star"
[ -x "$LAUNCHER" ] || skip "no Star.app in $APP_IMAGE (build it: ./gradlew createDistributable, see gherkin/ui/README.md)"

if [ $# -ge 2 ]; then WORK="$(mkdir -p "$2" && cd "$2" && pwd)"; else WORK="$(mktemp -d "${TMPDIR:-/tmp}/star-dock-reopen.XXXXXX")"; fi
HOME_DIR="$WORK/home"; LOG="$WORK/star.log"
rm -rf "$HOME_DIR" "$LOG"; mkdir -p "$HOME_DIR"

# --- helpers ---------------------------------------------------------------------------------------------------
MIN=200   # the main window is 1280x800; AWT keeps tiny helper windows around, which are not the window
WINDOWS_JS='
ObjC.import("CoreGraphics");
function run(argv) {
  var pid = parseInt(argv[0], 10), out = [];
  var info = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(
    $.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, $.kCGNullWindowID)));
  for (var i = 0; i < info.length; i++) {
    var w = info[i];
    if (w.kCGWindowOwnerPID !== pid) continue;
    var b = w.kCGWindowBounds;
    out.push(["layer=" + w.kCGWindowLayer, Math.round(b.Width) + "x" + Math.round(b.Height), "at " + Math.round(b.X) + "," + Math.round(b.Y)].join(" "));
  }
  return out.join("\n");
}'
# Every on-screen window of pid, one "layer=L WxH at X,Y" per line.
windows_of() { osascript -l JavaScript -e "$WINDOWS_JS" "$1" 2>/dev/null; }
# The ones that are the main window: layer 0 and at least MIN by MIN.
big_windows_of() {
  windows_of "$1" | awk -v min="$MIN" '/^layer=0 / { split($2, s, "x"); if (s[1] >= min && s[2] >= min) print }'
}
has_big_window() { [ -n "$(big_windows_of "$1")" ]; }
no_big_window() { ! has_big_window "$1"; }
alive() { kill -0 "$1" 2>/dev/null; }

# The title of the app's front window, through System Events. Prints it; fails with System Events' own words.
title_of() {
  osascript -e "with timeout of 10 seconds
tell application \"System Events\" to get name of window 1 of (first process whose unix id is $1)
end timeout" 2>&1
}
click_close() {
  osascript -e "with timeout of 10 seconds
tell application \"System Events\" to click (first button of window 1 of (first process whose unix id is $1) whose subrole is \"AXCloseButton\")
end timeout" 2>&1
}

# True if osascript's error text says the permission to drive System Events is missing.
is_permission_error() {
  case "$1" in *-1743*|*-25211*|*"assistive access"*|*"not allowed"*|*"Not authorized"*|*"not authorized"*) return 0 ;; esac
  return 1
}

# Poll: wait_for <seconds> <command...> succeeds as soon as the command does; the limit is wall-clock time (a call
# to System Events can itself take seconds), and the command always gets one try.
wait_for() {
  local deadline=$(( SECONDS + $1 )); shift
  while :; do
    "$@" && return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.5
  done
}

PID=""
MADE_WORK=""
[ $# -ge 2 ] || MADE_WORK=1
cleanup() {
  local pids
  if [ -n "$PID" ] && alive "$PID"; then kill -TERM "$PID" 2>/dev/null; fi
  # A second instance, if `open -a` started one instead of reopening the first.
  pids="$(pgrep -f "$LAUNCHER" 2>/dev/null | grep -vx "$$" || true)"
  # shellcheck disable=SC2086
  [ -z "$pids" ] || kill -TERM $pids 2>/dev/null
  [ -z "$MADE_WORK" ] || rm -rf "$WORK"
}
trap cleanup EXIT

# What was seen, for a FAIL: the process, its windows, the app's own log.
report() {
  echo "  process $PID: $(if alive "$PID"; then echo running; else echo NOT running; fi)"
  local seen
  seen="$(windows_of "$PID")"
  echo "  on-screen windows of pid $PID:"
  if [ -n "$seen" ]; then echo "$seen" | sed 's/^/    /'; else echo "    (none)"; fi
  local others
  others="$(pgrep -f "$LAUNCHER" 2>/dev/null | grep -vx "$$" | grep -vx "$PID" | tr '\n' ' ' || true)"
  [ -z "$others" ] || echo "  another process running Star: $others"
  echo "  app output (last lines of $LOG):"
  tail -n 15 "$LOG" 2>/dev/null | sed 's/^/    /'
}
fail() { echo "FAIL: $*"; report; exit 1; }

# --- 1. start, with no sequence: the start screen ----------------------------------------------------------------
HOME="$HOME_DIR" JAVA_TOOL_OPTIONS="-Duser.home=$HOME_DIR" "$LAUNCHER" >"$LOG" 2>&1 &
PID=$!
echo "started $BUNDLE as pid $PID (HOME=$HOME_DIR)"

wait_for 90 has_big_window "$PID" || { alive "$PID" || fail "the app quit before showing a window"; fail "no main window on screen after 90 s"; }

# A launch from a terminal leaves the app behind; a user's launch (Dock, Finder) brings it forward, and until it is
# forward System Events sees no window of it. Do what the user's launch did.
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1 || true
# The window is on screen before the accessibility tree has it (a Java app's can be a minute behind, and System Events can take 20 s to answer), so ask until it answers.
read_title() { TITLE="$(title_of "$PID")"; }
wait_for 120 read_title || {
  is_permission_error "$TITLE" && skip "System Events may not read the app's window (grant Automation and Accessibility to this terminal or runner): $TITLE"
  # Not a refusal: System Events has no window for a process whose window is on screen. Either Accessibility is
  # not granted to it (it answers, with nothing) or the app does not expose its window; this check cannot tell which.
  skip "a window of pid $PID is on screen but System Events sees none after 120 s, so the close button cannot be clicked (Accessibility not granted to this terminal or runner, or the window is not in the accessibility tree): $TITLE"
}
[ "$TITLE" = "Star" ] || fail "the first window is titled \"$TITLE\", not the start screen's \"Star\""
echo "PASS 1/3: the main window is up on the start screen (pid $PID, title \"$TITLE\", $(big_windows_of "$PID" | head -n 1 | cut -d' ' -f2))"

# --- 2. close it as the user does: the process stays, no window is left ----------------------------------------------
OUT="$(click_close "$PID")" || {
  is_permission_error "$OUT" && skip "System Events refused the click (grant Accessibility to this terminal or runner): $OUT"
  fail "could not click the window's close button: $OUT"
}
# No sequence is open, so there is no pending work and no "Close Anyway" question to answer.
if ! wait_for 10 no_big_window "$PID"; then
  alive "$PID" && fail "the window is still on screen 10 s after its close button was clicked"
  fail "the app quit"
fi
sleep 2   # the app might quit a moment after the window went; a hidden window must not be mistaken for a dying app
alive "$PID" || fail "the window went and then the app quit (on a Mac it must keep running)"
no_big_window "$PID" || fail "a window came back on its own after the close"
echo "PASS 2/3: closed with the close button; pid $PID is still running and has no window on screen"

# --- 3. the Dock's reopen: the window is back, on the start screen ----------------------------------------------------
METHOD="open -a Star.app"
open -a "$BUNDLE" 2>&1 | sed 's/^/  open: /'
if ! wait_for 15 has_big_window "$PID"; then
  # `open -a` raises the app and asks it to reopen; if the window did not come, ask for the reopen alone.
  if alive "$PID" && no_big_window "$PID"; then
    echo "  open -a brought no window back in 15 s; trying a bare AppleScript reopen"
    METHOD="osascript reopen (open -a alone did not work)"
    osascript -e "tell application \"$BUNDLE\" to reopen" 2>&1 | sed 's/^/  osascript: /'
    wait_for 15 has_big_window "$PID" || true
  fi
fi
alive "$PID" || fail "the app quit when it was asked to reopen"
has_big_window "$PID" || fail "the window did not come back after the reopen event ($METHOD)"
TITLE="$(title_of "$PID")" || fail "the window is back but its title cannot be read: $TITLE"
[ "$TITLE" = "Star" ] || fail "the window is back but is titled \"$TITLE\", not the start screen's \"Star\""
echo "PASS 3/3: reopened with $METHOD; pid $PID has its main window back on the start screen (title \"$TITLE\", $(big_windows_of "$PID" | head -n 1 | cut -d' ' -f2))"
exit 0
