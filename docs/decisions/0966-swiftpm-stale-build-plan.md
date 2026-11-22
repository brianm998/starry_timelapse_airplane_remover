# 0966 — SwiftPM stale build plan

## Problem
Landing batches #607 and #630 (task #841) turned test-cli red with `cannot find 'LogOnChange' in scope` and
`cannot find 'horizonColumnsCache' in scope`. Both symbols live in StarCore files added that night. In the batch
checkout, `cli/.build/debug.yaml`, `plugin-tools.yaml` and `x86_64-apple-macosx/debug/description.json` were older
than those files while `build.db` was current: SwiftPM reused the cached build manifest and compiled StarCore through
`cli` without the new files. A fresh `.build` passed.

## Decision
Pass `--disable-build-manifest-caching` to every `swift build` / `swift test` (suite `command`, `narrow_command`) in
`.mason/mason.toml` and to the three swift calls in `.mason/scripts/shards.py`.

Flag verified on the installed toolchain (Apple Swift 6.2.1, swift-driver 1.127.14.1) with
`swift build --help-hidden`: `--enable-build-manifest-caching/--disable-build-manifest-caching`
(default: enabled). It is a shared build option, so `swift test` and `swift test list` accept it.

The plan is regenerated every invocation; llbuild's `build.db` and the object files stay, so only changed sources
recompile. `scripts/exit/s973.sh` shows both on two scratch packages. `pipeline/tests/test_mason_toml_swiftpm.py`
keeps new suites from dropping the flag.

## Not done
Deleting `.build` (loses incrementality), and a plan-hash helper script (not needed: the flag exists).
The root cause inside SwiftPM (why a dependency's new file did not invalidate the cached manifest) was not
investigated beyond the evidence above.
