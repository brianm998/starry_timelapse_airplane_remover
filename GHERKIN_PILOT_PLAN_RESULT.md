# Gherkin pilot: result

**Status: implemented; all 3 clients pass locally; the six CI legs were NOT run.**
Nothing is committed or pushed (not asked). `GHERKIN_PILOT_PLAN.md` has been removed.

## What exists

- `gherkin/` : `features/openAndProcess.feature`, `steps.json`, `params.json`, `generate.sh`, `README.md`,
  `StarGherkin/` (SwiftPM: `StarGherkinKernel` library, `star-gherkin-gen` executable; no StarCore dependency).
- Generator: Ruby `gherkin` discovery + `--format` sniffing ported from Preffect; takes only feature/scenario names,
  tags, step keyword/text; fails with file:line on unknown step, missing placeholder default, >1 scenario,
  Background/Outline/Rule, bad basename/tag; wipes and rewrites every generated location; own SHA-256 so it builds
  on Linux. Generated Swift and Kotlin are typed literals (no JSON at run time); test entry points are generated
  per (feature, client tag). All negative cases were exercised.
- Runners: `cli/Tests/GherkinTests/CliFeatureRunner.swift`, `gui/starUITests/GuiFeatureRunner.swift`,
  `star-desktop/src/gherkinTest/.../DesktopFeatureRunner.kt` (+ `Model.kt`). Each: `methodMap`, per-step reporting,
  fails on zero steps or unimplemented step, never skips.
- App seams: gui launch arg `-StarUITestOpenSequence` (`ViewModel.openSequenceFromUITestArgument`, also skips the
  GitHub release check under test) and identifiers `startup.horizon.yes`, `startup.moving.static`,
  `startup.selecthorizon.no`, `startup.removal.start`, `prompt.pre.no`, `processing.progress`
  (label `<complete>/<total>/<running|idle>`); desktop testTags `process.frames`, `settings.process`,
  `prompt.pre.no`, `processing.progress` (same stateDescription).
- Build wiring: `cli/Package.swift` test target; `gherkinTest` source set + task in `star-desktop/build.gradle.kts`
  (not part of `./gradlew test`); gui pbxproj (4 entries each for the 2 new files, package ref/product/framework
  for the kernel, `MACOSX_DEPLOYMENT_TARGET=15.0` and `SDKROOT=macosx` on starUITests) and `starUITests` added to
  the `star` scheme's Testables.
- `.github/workflows/gherkin.yml`: generate-check, cli-linux, cli-macos, mac-gui (+ffmpeg), desktop-linux/-windows/-macos,
  each ending in a vacuous-green check. YAML parses; never executed. Duplicated (collapse later): apt/Eigen/Swift/MSVC/
  OpenCV/StarDecisionTrees setup from cli.yml, stard build steps from kotlin-client.yml, ci-assets fetch.

## Measured

| Client | Result | Output frames | Wall clock |
|---|---|---|---|
| cli (macOS, debug star, iMac Pro) | PASS | 19 | 154-171 s |
| desktop (macOS, real stard release) | PASS (`tests="1" skipped="0" failures="0"`) | 19 | ~50 s |
| mac gui (XCUITest, after automation mode was enabled) | PASS (`Executed 1 test, with 0 failures`) | 19 | ~995 s including the build; the run itself ~3 min |
| CI legs | not run | n/a | n/a |

Red proof (local, via `STAR_GHERKIN_EXPECTED_OUTPUTS=18`): cli and desktop both fail with "expected 18 but was 19". Not done for gui/CI.
Parser diff: gherkin 9.0.0 vs cucumber-gherkin 42.0.1 (Ruby 3.3): byte-identical generated output.

## gui and CI

- The gui test ran locally with `xcodebuild test ... -only-testing:starUITests/GeneratedFeatureUITests CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`
  and passed: the UI-test runner can read the output directory, and ad-hoc signing worked. Not yet run on a hosted runner.
- The `processing.progress` element's *value* comes through empty with `.accessibilityElement(children: .ignore)`; the
  state is carried in its *label* instead (`<complete>/<total>/<running|idle>`). A first run polled the value forever
  while the app had long finished.
- Red-on-purpose was not repeated for the gui; CI legs need a push, which I did not do.

## Things that turned out wrong / worth knowing

- Compose headless: composing `StarApp`'s start screen blocks forever (JavaFX video background can't start). The runner
  waits for `AppViewModel.screen` to become `Sequence` *before* `setContent`.
- `waitUntil`'s timeout did not fire in real time under redraw; the runner keeps its own real-time deadline and dumps the UI tree on timeout.
- Settings dialog's Process Now button is below a 1024x768 window, so clicks were silently lost; the runner uses a 1400x1100 window (`runDesktopComposeUiTest`).
- Desktop opens in edit mode (skips startup prompts) and goes Process frames -> settings -> Process Now -> prompt "No"; the gui walks the startup wizard instead (defaults: horizon yes, static, no hand-painted horizon). The two flows differ.
- Pre-existing bug, not fixed: `SequenceViewModel.fullResolutionVersion` is declared after the `init` block that uses it, so `watchFullResolution()`'s `combine` gets a null flow and throws an NPE (seen in every desktop run's stderr).
- `gui/starUITests` stubs on disk were named `ntar_gui*` while the pbxproj pointed at `starUITests*.swift`; the target never compiled anything. Replaced.
- cli test runs a debug `star` (3 min here; slower on 4-core runners, timeout set to 120 min). Set `STAR_CLI_PATH` to a release binary to speed up.
- The pinned gem version in CI is 42.0.1 (current at the time).
- Windows desktop leg is the likeliest to need fixes (untested `cygpath` stard path, headless AWT on Windows).

## Next steps

1. Push a branch/PR to `develop`; fix whatever the six legs surface; add the throwaway red-assertion commit per leg.
3. Consider fixing the `fullResolutionVersion` init-order bug; collapse duplicated CI setup.
