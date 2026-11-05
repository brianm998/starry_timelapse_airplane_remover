# Shared by asan-xctest.sh and gmalloc-xctest.sh (sourced, not run).
HUNT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -P "$HUNT_DIR/../.." && pwd -P)"
STARPIPE="$REPO/pipeline/bin/starpipe"
TEST="${1:-StarAlignedHorizonMaskTests/testConcurrentFullFrameMasksAlongsideOtherNativeWorkKeepTheHeapIntact}"
SCRATCH="${HEAP_HUNT_SCRATCH:-$REPO/.heap-hunt-scratch}"   # inside the worktree (git-ignored)
mkdir -p "$SCRATCH"

# The real xctest binary. Not `xcrun xctest` and not a #!/bin/bash wrapper: SIP strips DYLD_* from both.
XCTEST="$(xcrun -f xctest)"

# write_wrapper <path> <env assignment>...: a tiny script that exports the env and execs the real binary.
# It must be run as `<wrapper> <xctest> ...` where the wrapper itself is exec'd by starpipe, and it
# execs the argument list, so DYLD_INSERT_LIBRARIES is set in the xctest process itself.
write_wrapper() {
  local path="$1"; shift
  { echo '#!/bin/sh'; for e in "$@"; do echo "export $e"; done; echo 'exec "$@"'; } > "$path"
  chmod +x "$path"
}
