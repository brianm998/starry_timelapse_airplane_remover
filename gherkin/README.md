# Gherkin features

One Gherkin corpus drives the same user flow through three Star clients, each run on GitHub
Actions (`.github/workflows/gherkin.yml`):

| Client | Tag | Driver | Runs |
|---|---|---|---|
| `star` cli | `@cli` | XCTest running the built `star` binary as a subprocess (`cli/Tests/GherkinTests`) | ubuntu-24.04, macos-15 |
| macOS gui (`Star.app`) | `@mac-gui` | XCUITest (`gui/starUITests`) | macos-15 |
| Kotlin/Compose desktop | `@desktop` | `runComposeUiTest` against a real `stard` (`star-desktop/src/gherkinTest`) | ubuntu-24.04, windows-2022, macos-15 |

The `.feature` files are **never parsed at test run time**. `star-gherkin-gen` parses them (with the Ruby
`gherkin` CLI) and writes typed Swift and Kotlin sources, which are committed, so a fresh clone builds
without Ruby. Only someone editing a `.feature`, `steps.json` or `params.json` needs it.

## Layout

```
gherkin/
  features/*.feature          THE corpus. One Feature and exactly one Scenario per file.
  steps.json                  THE step vocabulary: [{ "case": "openSequence", "text": "I open the sequence {sequence}" }, …]
  params.json                 placeholder values: { "default": {…}, "cli": {…}, "mac-gui": {…}, "desktop": {…} }
  generate.sh                 runs the generator
  StarGherkin/                SwiftPM package (no StarCore dependency: no OpenCV)
    Sources/StarGherkinKernel/        Model.swift (hand-written) + Generated/*.generated.swift
    Sources/star-gherkin-gen/         the generator
```

Generated (committed, never edit; each starts with `// @generated` and a `source-hash`):

* `gherkin/StarGherkin/Sources/StarGherkinKernel/Generated/{StepAction,Features}.generated.swift`
* `cli/Tests/GherkinTests/GeneratedFeatureTests.swift`
* `gui/starUITests/GeneratedFeatureUITests.swift`
* `star-desktop/src/gherkinTest/kotlin/com/star/desktop/gherkin/generated/{StepAction,Features,GeneratedFeatureTests}.kt`

* `gherkin/generated/datasets-{cli,mac-gui,desktop}.txt`: the `data:` datasets each client's features need; CI
  runs `test_data/fetch.sh $(cat …)` on exactly that list.

Hand-written runners: `cli/Tests/GherkinTests/CliFeatureRunner.swift`,
`gui/starUITests/GuiFeatureRunner.swift`,
`star-desktop/src/gherkinTest/kotlin/com/star/desktop/gherkin/{Model,DesktopFeatureRunner}.kt`.

## Installing the parser (only to regenerate)

```bash
gem install cucumber-gherkin      # any version; CI pins one
```

The generator looks for `$GHERKIN_BIN`, `/usr/local/bin/gherkin`, `/opt/homebrew/bin/gherkin`, each Homebrew
Ruby's gem bin directory, then `PATH`. It runs `--help` on each and uses the first that actually launches
(system Ruby's gherkin 9.0.0 is present on an Apple-silicon Mac but its protobuf is x86_64-only and never
loads). It passes `--format=ndjson` only when `--help` mentions `--format`; cucumber-gherkin ≥ ~20 dropped
the flag. gherkin 9.0.0 and cucumber-gherkin 42.0.1 were checked to produce byte-identical output.

## Adding a feature

1. Create `gherkin/features/<lowerCamelName>.feature`. The basename must be lowerCamelCase and the
   `Feature:` line must carry its own `@<lowerCamelName>` tag plus a tag per client that should run it
   (`@cli`, `@mac-gui`, `@desktop`). A client without its tag gets no test method, deliberately.
2. One Scenario only. There is no state reset between scenarios, so a second one would inherit the first one's
   state. `Background`, `Scenario Outline` and `Rule` are rejected.
3. Every step must match a `steps.json` entry **exactly**: no regexes, no Cucumber expressions.
   `{placeholders}` stay literal in the file; the runner supplies their values (below).
4. `gherkin/generate.sh`, then commit the generated files.

The generator fails, with file:line, on an unknown step, a placeholder with no default, a bad basename or
tag, a second scenario, or an unsupported construct. It deletes and rewrites every generated location each
run, so a deleted feature leaves no orphan test behind.

## Adding a step

1. Add `{ "case": "myStep", "text": "…" }` to `steps.json`.
2. `gherkin/generate.sh` (this adds the case to Swift `StepAction` and Kotlin `StepAction`).
3. Implement it in each client's `methodMap` that runs a feature using it: `CliFeatureRunner`,
   `GuiFeatureRunner`, `DesktopFeatureRunner`. A missing entry fails the run listing every implemented step.

## Placeholder values

A `{name}` resolves, in order, from env var `STAR_GHERKIN_<UPPER_NAME>`, the client's override in
`params.json`, then `default`. Under xcodebuild set `TEST_RUNNER_STAR_GHERKIN_<NAME>` (the prefix is
stripped). Relative paths resolve against the repo root. A value of the form `data:<name>` is a dataset from
`test_data/datasets.json`, fetched into the test-data cache by `test_data/fetch.sh <name>` (see
`test_data/README.md`: cache directory, `STAR_TEST_DATA`, how to add one). The runners only resolve it and fail
with the fetch command if it is absent. A sequence is always **copied to a fresh temp
directory** first: star derives its temp and output paths from the input directory's name, so processing a
directory in place would pick up the last run's state.

## Running locally

Each runner fails (never skips) on missing setup, and refuses a feature with no steps.

Fetch the data first: `test_data/fetch.sh $(cat gherkin/generated/datasets-<client>.txt)`.

* **cli** (needs `opencv` and `StarDecisionTrees` built, as for any cli build). Like CI, one release compile:
  ```bash
  swift test -c release -Xswiftc -enable-testing --disable-swift-testing --package-path cli --filter GherkinTests
  ```
  (`-enable-testing` because the cli's other test target is `@testable import star`; `--disable-swift-testing` because the second Swift Testing pass starts `star`'s own `@main`, which rejects `-c release` and exits 1.) It runs the `star` beside the
  test bundle; a debug `swift test` works too but takes ~20 minutes on the 19-frame sequence. `STAR_CLI_PATH`
  overrides the binary. Never use `cli/star.xcodeproj`: it cannot link.
* **desktop** (needs a `stard`: `cd daemon && swift build -c release`):
  ```bash
  cd star-desktop && ./gradlew gherkinTest -Pstar.stard.path=$PWD/../daemon/.build/release/stard
  ```
  Offscreen (`java.awt.headless=true`); no Xvfb. Not part of `./gradlew test`.
* **mac gui** (needs `gui/videos/*.mp4`, ffmpeg in `external_binaries/bin`, and opencv/StarDecisionTrees):
  ```bash
  sudo automationmodetool enable-automationmode-without-authentication   # once per machine; hosted runners have it
  xcodebuild test -project gui/star.xcodeproj -scheme star -configuration Release ENABLE_TESTABILITY=YES -only-testing:starUITests/GeneratedFeatureUITests \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  ```
  `-configuration Release` is what CI passes (the scheme's default stays Debug for development). Use `-scheme star`, never `-target Star`, and no `-destination`. Without automation mode `xcodebuild
  test` hangs at "Timed out while enabling automation mode".

## The seams the tests rely on

* gui: launch argument `-StarUITestOpenSequence <dir>` (`ViewModel.openSequenceFromUITestArgument`) opens a
  sequence the way the open panel does; it also suppresses the GitHub release check. Accessibility
  identifiers: `startup.horizon.yes`, `startup.moving.static`, `startup.selecthorizon.no`,
  `startup.removal.start`, `prompt.pre.no`, and `processing.progress` whose label reads
  `<complete>/<total>/<running|idle>`.
* desktop: `Modifier.testTag`s `process.frames`, `settings.process`, `prompt.pre.no`, and
  `processing.progress` (same `stateDescription`). The sequence opens through the `AppViewModel` auto-open
  dev hook (`autoOpenPath`, `autoMode = "edit"`).

## Guarding against vacuous greens

`xcodebuild -only-testing:` matching nothing exits 0 having run nothing, so each CI leg also checks the
log: `Executed 1 test, with 0 failures` for xcodebuild, `testOpenAndProcessFeature` passed for swift test,
and `tests="1"` / `skipped="0"` in `build/test-results/gherkinTest/*.xml` for Gradle.
