# Plan: a `cli (windows-2022)` leg for the Gherkin workflow

Handoff for an agent. Investigated 2026-10-15 at `3fc6b3cc` (develop).

## First: what already exists (do not rebuild it)

The `star` cli **already builds, packages and ships on Windows.** Don't redo any of this:

- `.github/workflows/cli.yml` job `windows` (windows-2022, Swift 6.1, MSVC 14.40 + SDK 22621 pins) runs
  `release_windows.sh`. That script builds `star.exe` and makes a `.zip` and an NSIS `_setup.exe`. Then it
  runs the 19-frame smoke test on `test_data/test_a7sii_10`.
- `windows-e2e` installs both packages on a fresh runner. It runs `cli/packaging/check-windows-dependencies.sh`
  and `cli/packaging/self-test.sh` on each.
- Both jobs pass on develop (run 38665164862). Releases 0.12.1–0.12.3 ship `star_cli_<v>_windows_x64.zip`
  and `star_cli_<v>_windows_x64_setup.exe`, and `docs/index.html` links to both. **Exception:** 0.12.0
  has the `_setup.exe` but no `.zip`. That was a one-off; later releases have both.

**The missing piece is the Gherkin leg.** `.github/workflows/gherkin.yml` runs the `@cli` features only on
`cli-linux` and `cli-macos`. The cli has no Windows leg, though `desktop-windows` exists and passes.
`gherkin/README.md` line 8 lists the cli runners as "ubuntu-24.04, macos-15". The goal is to add
`cli-windows` and get it green for the right reason.

No CI job has ever run `swift test` on the cli package on Windows. `cli.yml` only runs `swift build`, so
both test targets are new to Windows. Expect the first few runs to fail.

## Done means

1. `gherkin.yml` has a `cli-windows` job: `name: cli (windows-2022)`, `runs-on: windows-2022`.
   On a push or PR to develop, it runs `GeneratedFeatureTests.testOpenAndProcessFeature` against a release
   `star.exe`, and the test passes.
2. The job ends with the same vacuous-green check the other cli legs use. That check must be shown to
   catch a fake pass: push a throwaway commit with a deliberately wrong assertion (for example,
   `expected_outputs` → 18 in a per-client override). The leg must go red on it. Then revert.
3. The `cli-linux` and `cli-macos` legs, and every leg of `cli.yml`, stay green.
4. `gherkin/README.md`'s client table lists windows-2022 for `star` cli.
5. The leg's wall clock is reported in the PR description. `desktop-windows` takes about 10–20 minutes,
   and its timeout is 150 minutes.

## Known code problems to fix (read, not yet run)

All of these are in `cli/Tests/GherkinTests/CliFeatureRunner.swift`:

1. **`starBinary()` looks for `star`, not `star.exe`.** It does
   `products.appendingPathComponent("star")`. On Windows the file is `star.exe`. Add `#if os(Windows)`
   to append `.exe`. Alternatively, the job can set `STAR_CLI_PATH`, but fix the default either way.
2. **The products directory comes from `Bundle.main.bundleURL` on every non-macOS platform.** On Windows
   it is unknown whether this is `.build/<triple>/release`. SwiftPM's Windows test runner is
   `<Package>PackageTests.xctest`, an .exe, and `Bundle.main` may resolve to it or to the directory that
   holds it. Print the path on the first run. The simplest robust fix is for the CI job to pass
   `STAR_CLI_PATH`. Get the path from `swift build -c release --package-path cli --show-bin-path` and
   run it through `cygpath -w`. That way the default only has to be right for local runs.
3. **The absolute-path check is POSIX-only.** In `openSequence()`, `given.hasPrefix("/")` misses
   `C:\…`. The feature passes `data:a7sii_10`, which goes through `TestData.resolve`, so this isn't on
   the CI path. Still, fix it with `URL(fileURLWithPath:)` semantics or by checking for a drive letter.
   That way a plain-path `{sequence}` also works on Windows.
4. **Scratch dir names.** `FileManager.default.temporaryDirectory` on a Windows runner is under
   `C:\Users\runneradmin\AppData\Local\Temp`. star derives its temp and output paths from the input
   directory's name (see `CliFeatureRunner.openSequence`'s comment), so look for Windows path-length
   issues (MAX_PATH 260) in the output paths. If they appear, set `TMP` or `TEMP` to something short,
   such as `C:\t`, in the job.
5. **`#filePath` is a backslash path on Windows.** `repoRoot` uses
   `URL(fileURLWithPath: #filePath)` with four `deletingLastPathComponent()` calls. This should work, but
   verify it, because `dataCache()` falls back to `<repoRoot>/.test-data`. Setting `STAR_TEST_DATA` in
   the job (via `cygpath -w`) removes the dependency.

## Biggest unknown: the `starTests` target on Windows

`swift test --filter GherkinTests` still compiles every test target. The cli has a second one,
`starTests`, which is `@testable import star` against an **executable** target. It also links
`StarDecisionTrees.lib` through unsafeFlags (see `cli/Package.swift`). Neither has ever been tried on
Windows. Possible failures:

- Testing an executable target with `@testable` on Windows needs SwiftPM to rename `main`. Support on
  Windows has historically lagged Linux and macOS.
- `-enable-testing` in a release build plus the `-Xlinker <...>/StarDecisionTrees.lib` flags under
  lld-link or link.exe.
- `ExitCodeTests` hard-codes `/tmp/...` strings. These are only string assertions on
  `frameErrorSummary`, so they're probably fine at compile time.

If `starTests` won't build on Windows, look for the cheapest real fix first. If there is none, the
fallback is to drop the target from the manifest on Windows only. `Package.swift` already branches on
`#if os(Windows)`, so build `targets` conditionally. Note it in the PR as a follow-up. Don't make the
Windows leg skip tests in a way that could pass vacuously.

## The job to add

Copy `desktop-windows` in `gherkin.yml` for everything up to and including "Build StarDecisionTrees (if not
cached)". That covers checkout, test-data cache and fetch, Swift 6.1 via `compnerd/gha-setup-swift`,
Eigen to `C:\eigen3`, MSVC 14.40, the vcvars pin to SDK 22621, the modulemap copy, and the OpenCV and
StarDecisionTrees caches. Keep the cache keys **identical** so this leg shares caches with `cli.yml`'s
`windows` job and with `desktop-windows`. Then make these changes:

- Use the test-data cache key `testdata-cli-…` and fetch `gherkin/generated/datasets-cli.txt`, as the
  other cli legs do. Fetching on Git Bash already works on windows-2022: `desktop-windows` does it and
  passes, which settles the "unverified Git Bash tar/mktemp" item in
  `GHERKIN_SPEED_AND_TEST_DATA_PLAN_RESULT.md`.
- `defaults.run.shell: bash` (Git Bash), and `timeout-minutes: 150`.
- Run step: the same command as the Linux and macOS legs, keeping their reasons for each flag (see the
  comment on `cli-linux`'s run step):
  `swift test -c release -Xswiftc -enable-testing --disable-swift-testing --package-path cli --filter GherkinTests 2>&1 | tee gherkin-cli.log`
  Before it, build with `swift build -c release --package-path cli` and export `STAR_CLI_PATH`
  (Windows-style path) and `STAR_TEST_DATA`. **Do not set `CL=/D…`**, because it breaks OpenCV's CMake
  compiler probe (see `cli.yml` and `release_windows.sh`).
- Vacuous-green step: copy it from `cli-linux`. Check that XCTest's output on Windows really prints
  `Executed 1 test, with 0 failures` and `testOpenAndProcessFeature … passed` in the same form. The
  Windows XCTest is swift-corelibs-xctest, as on Linux, so it should. If the wording differs, adjust the
  greps rather than loosening them.
- Upload `gherkin-cli.log` on failure (`if: always()`). It's the only diagnostic you get.

`star.exe` runs here from the build tree, with the toolchain on PATH, so DLL bundling is not under test in
this leg. `cli.yml`'s `windows-e2e` already covers that. Don't duplicate it.

## How to iterate

This Mac can't build for Windows, so every check runs on CI. Branch from `develop`, push, and open a
PR so `gherkin.yml`'s `pull_request` trigger fires. Its path filters include `cli/**` and
`.github/workflows/gherkin.yml`. While iterating, use `workflow_dispatch` or comment out the other legs
on the branch (restore them before merging) so each round costs one Windows job instead of seven.
OpenCV is about 15–30 minutes cold, so a cache hit matters. The keys above match `cli.yml`'s, which
develop keeps warm.

## Out of scope

- The Windows cli build or packaging itself. It exists and passes; see above.
- Collapsing the duplicated Windows toolchain setup into a reusable workflow. It is now duplicated 4×
  (`cli.yml`, `kotlin-client.yml`, and gherkin's desktop and cli legs). That's worth a separate change
  once this one is green.
- The red `desktop (macos-15)` leg on develop (run 38665042188). It's unrelated to this work.
