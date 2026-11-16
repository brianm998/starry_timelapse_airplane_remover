# 0491: the Debug test host has its own bundle id

## Context
Since 2026-11-15 `test-gui` failed with "The test runner hung before establishing connection."
The owner's /Applications/Star.app (com.star) had been running, and the Debug test host had the
same bundle id, so LaunchServices/XCTest can hand the launch to the running instance. This is the
likely cause, not a confirmed one.

## Decision
- The star app target's Debug configuration uses `com.star.debug`. Release stays `com.star`
  (release.sh's `--identifier com.star` is unaffected). The test targets keep their ids.
- `xcodebuild-signed.sh` prints a non-fatal note when a test runs while /Applications/Star.app runs.
- The `[impact]` map lists gui/ by subtree instead of `gui/**`; `gui/*.sh` and
  `gui/*.entitlements.plist` map to nothing, so a script-only change selects no gui suite.

## Consequences
- macOS privacy approvals (removable volumes) are per bundle id and signing identity, so the
  Debug build asks for them once more under `com.star.debug`.
- Sandboxed agent shells cannot run hosted tests: amfid/syspolicyd lookups fail there ("library
  load mig callout failed"). Run test-gui through masond.
