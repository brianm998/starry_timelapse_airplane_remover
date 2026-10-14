# Gherkin pilot: one `.feature` file, three Star clients, GitHub Actions

Build instructions for the agent implementing the pilot. Read all of it before writing code;
the "traps" sections are what Preffect-Mobile paid for in failed runs.

## Goal

A single Gherkin file, `gherkin/features/openAndProcess.feature`, drives the same user flow
through three clients. Each client runs it on GitHub Actions, and each run has to prove it
executed something real:

| Client | Runner(s) | Driver |
|---|---|---|
| `star` cli | `ubuntu-24.04`, `macos-15` | XCTest that runs the built `star` binary as a subprocess |
| macOS SwiftUI gui (`Star.app`) | `macos-15` | XCUITest (`gui/starUITests`) |
| Kotlin/Compose desktop (`star-desktop`) | `ubuntu-24.04`, `windows-2022`, `macos-15` | `runComposeUiTest` against a real `stard` |

The repo is **public**, so hosted runners (macOS included) cost nothing. Minutes aren't a
reason to cut a platform.

**Done means:** all six legs are green on a PR, and each leg's log shows its scenario actually
executed (see "Vacuous green" below). A deliberately broken assertion turns each leg red. Prove
that once with a throwaway commit, then revert it.

## Already established (don't re-research)

- **XCUITest works on hosted macOS runners.** The actions/runner-images build script
  `images/macos/scripts/build/configure-machine.sh` runs
  `automationmodetool enable-automationmode-without-authentication`, and
  `scripts/tests/System.Tests.ps1` asserts that it took. Don't add that step to CI. **Locally**
  (Brian's iMac) it has *not* been done: run
  `sudo automationmodetool enable-automationmode-without-authentication` once, or
  `xcodebuild test` hangs at "Timed out while enabling automation mode".
- **Compose UI tests render offscreen.** This was measured in star-desktop on 2026-10-14 with
  `JAVA_TOOL_OPTIONS=-Djava.awt.headless=true`: a `runComposeUiTest` click,
  `assertTextEquals` and `captureToImage` (1024x768) all passed under the existing JUnit
  Platform `test` task. The dependency was `testImplementation(compose.desktop.uiTestJUnit4)`,
  and no vintage engine was needed. **No Xvfb on Linux.**
- **Packaged Compose apps can't be black-box driven** on Linux (Compose has no Linux
  accessibility). Don't attempt Appium/WinAppDriver/AT-SPI. The existing `*-e2e`
  `Star --self-test` jobs already cover the installed packages.
- **The Ruby `gherkin` CLI is the parser.** It is the only reliable Gherkin parser available
  here. Nothing parses `.feature` text at test run time, on any client. Parsing happens at
  generation time, and the clients compile the result.

## How Preffect-Mobile does it, and what to copy

Reference checkout: `/Users/brian/git/Preffect-Mobile` (read-only for you). Files worth
reading:

- `gherkin/README.md`: the "five edits" and the naming traps. Read it in full.
- `iOS/PreffectGherkin/Tools/gherkin-prebuild-tool/{main,Parser}.swift`: the generator.
- `iOS/PreffectGherkin/Sources/PreffectGherkinKernel/{Feature,StepAction,StepActionType,StepKeyword}.swift`:
  the data model.
- `iOS/PreffectGherkin/Sources/PreffectGherkinKernel/Generated/login.generated.swift`: what
  the generator emits.
- `iOS/PreffectUITests/UIFeatureRunner.swift` (`methodMap`, `run(_:)`, `perform(_:)`) and
  `XCTestCase+Gherkin.swift`: the XCUITest runner.
- `pipeline/bin/gherkin-lint`: the wiring lint and the source-hash drift guard (rule 12).
- `.github/workflows/ci-ios-gherkin-cli.yml`: how CI runs the lint.

The mechanics:

1. **Single corpus.** `gherkin/features/*.feature` at the repo root. No client owns them or
   copies them. One `Feature:` per file, **one `Scenario:` per file** (a hard rule; there is no
   state reset between scenarios). Basenames are lowerCamelCase, with a matching `@<basename>`
   tag.
2. **Build-time parse.** `make -C iOS/PreffectGherkin generate` runs a Swift executable. For
   each `.feature`, it shells out to the Ruby CLI
   (`gherkin --no-source --no-pickles --predictable-ids [--format=ndjson] <file>`), decodes
   the `gherkinDocument.feature` envelope, and writes `Generated/<name>.generated.swift`. That
   file holds the Feature as JSON in a string literal, plus a `// source-hash: <sha256 of the
   .feature bytes>` header. It also writes `AllFeatures.generated.swift`, which lists them all.
   **Generated files are committed.** CI never runs the generator. It recomputes the hash in
   pure Python and fails on mismatch.
3. **Parser discovery.** The generator tries `$GHERKIN_BIN`, then `/usr/local/bin/gherkin`,
   `/opt/homebrew/bin/gherkin` and Homebrew Ruby gem bins. It runs `--help` on each candidate
   and uses the first one that actually launches. On Apple Silicon, system Ruby's gherkin 9.0.0
   is present but won't load (x86-only protobuf). It passes `--format=ndjson` only when
   `--help` mentions `--format`, because cucumber-gherkin ≥ ~20 dropped the flag and emits
   ndjson by default. This iMac has gherkin **9.0.0** on system Ruby 2.6 (x86_64), and it
   works.
4. **Closed step vocabulary.** Step text is matched **exactly** against an enum
   (`StepAction: String`, e.g. `case connectToHost = "I connect to {host}"`). There are no
   regexes and no Cucumber expressions. `{placeholders}` stay literal in the feature file. The
   runner supplies their values from suite params and env vars
   (`PREFFECT_TEST_*`, read in `XCTestCase+Gherkin.swift`). Unknown text decodes to
   `.unhandled(String)` and throws at run time.
5. **Runner = dispatch table.** Each client has `methodMap: [StepAction: (Runner) throws -> Void]`.
   `run(feature)` walks the steps and wraps each one in `XCTContext.runActivity`, so the report
   names the failing step. A missing entry throws an error that lists every implemented step.
6. **Test entry points are hand-written:**
   `func testLoginFeature() throws { try runGherkinFeature(try login.feature()) }` in
   `LoginFeatureUITests.swift`.

### What Preffect got wrong, which the pilot must not repeat

- **Android parses at run time** with a hand-rolled ~40-line regex parser
  (`android/preffectgherkin/.../Parser.kt`). It reads the `.feature` files bundled into the
  jar, from a **hand-maintained** `FEATURE_FILENAMES` list that silently drops missing
  entries. Star's Kotlin side must consume **generated** code from the same Ruby parse, like
  Swift does.
- **Two hand-mirrored step enums** (`StepAction.swift` and `StepAction.kt`, "identical
  byte-for-byte"). Generate both from one source instead.
- **Hand-written test methods** whose names the harness has to guess. The result was silent
  skips (`ios_gui_no_test_method`) and *vacuous greens*: `xcodebuild -only-testing:` matching
  nothing exits 0 having run zero tests. `goalOnboarding` "passed" twice that way, once with
  the screen deliberately broken. Generate the entry points instead.
- **The generator never prunes**, so deleted features leave orphan wrappers that keep
  compiling. Clean the output directory on every run.
- **It embeds JSON in a string and decodes it at run time**, so an unknown step only fails
  when that test runs. Emit typed literals instead, so an unknown step fails generation.

## Star design

### Layout

```
gherkin/
  README.md                         how to add a feature / step (short; see Preffect's for tone)
  features/openAndProcess.feature
  steps.json                        THE step vocabulary: [{ "case": "openSequence", "text": "I open the sequence {sequence}" }, …]
  params.json                       default placeholder values: { "sequence": "test_data/test_a7sii_10", "expected_outputs": "19" }
  generate.sh                       one command: runs the generator, writes every output below
  StarGherkin/                      SwiftPM package
    Package.swift                   products: library StarGherkinKernel; executable star-gherkin-gen
    Sources/StarGherkinKernel/
      Model.swift                   Feature/Scenario/Step/StepKeyword (plain structs, Sendable, no Codable needed)
      Generated/StepAction.generated.swift
      Generated/Features.generated.swift
    Sources/star-gherkin-gen/       the generator (port Preffect's Parser.swift discovery + --format sniffing)
star-desktop/src/gherkinTest/kotlin/com/star/desktop/gherkin/
  generated/StepAction.kt, Features.kt, GeneratedFeatureTests.kt
  DesktopFeatureRunner.kt           hand-written
gui/starUITests/
  GeneratedFeatureUITests.swift     generated (fixed filename: added to the pbxproj ONCE)
  GuiFeatureRunner.swift            hand-written
cli/Tests/GherkinTests/
  GeneratedFeatureTests.swift       generated
  CliFeatureRunner.swift            hand-written
```

`StarGherkin` is a standalone package. Follow the repo's standalone-tool pattern
(swift-tools-version 6.0, `static let configuration`), but **don't depend on StarCore**. The
kernel has to stay pure data, so it links into the cli tests and the UI-test bundle without
pulling in OpenCV.

### The feature

```gherkin
@openAndProcess @cli @mac-gui @desktop
Feature: open and process

  Scenario: Process the bundled test sequence
    Given I open the sequence {sequence}
     When I process every frame
     Then {expected_outputs} output frames are written
```

This parses as-is with the iMac's gherkin 9.0.0 (checked). **Client tags** (`@cli`,
`@mac-gui`, `@desktop`) on the `Feature:` line decide which clients get a generated test
method. A feature lacking a client's tag gets no method on that client, which is deliberate and
visible in the generated file.

`19` comes from the cli smoke test in `cli.yml`. **Measure what each GUI actually writes for
this sequence before trusting it.** If a client legitimately differs, give that client its own
param override (`params.json` → `{ "default": {…}, "mac-gui": {…} }`) rather than weakening
the assertion.

### The generator (`star-gherkin-gen`)

Inputs: `gherkin/features/`, `gherkin/steps.json`, `gherkin/params.json`. Steps:

1. Parse every `.feature` with the Ruby CLI (Preffect's discovery and `--format` sniffing).
   Extract **only** feature name, tags, scenario name, step keyword and step text. Normalise
   the keyword by trimming its trailing space. Ignore ids, locations and the uri. That keeps the
   output **identical across gherkin 9.x and current cucumber-gherkin**, so CI can regenerate
   and diff (see CI below).
2. Fail generation, with file:line, on any of these:
   - more than one Scenario per file
   - a `Background`, `Scenario Outline` or `Rule` (unsupported in the pilot, so fail loudly
     rather than drop it)
   - a basename that isn't lowerCamelCase or doesn't match its `@tag`
   - **step text with no exact match in `steps.json`**
   - a `{placeholder}` with no default in `params.json`
3. `rm -rf` each Generated output location, then write:
   - Swift `StepAction.generated.swift` (`enum StepAction: String, CaseIterable, Sendable`) and
     Kotlin `StepAction.kt` (`enum class StepAction(val text: String)`), both from
     `steps.json`.
   - Swift and Kotlin `Features` files as **typed literals**, e.g.
     `Step(.given, .openSequence)`. No JSON at run time. Include the params defaults.
   - One test entry point per (feature, client tag), with names derived mechanically:
     `openAndProcess` → Swift `func testOpenAndProcessFeature()`, Kotlin
     `fun openAndProcessFeature()`. Each just calls its client's runner:
     `try GuiFeatureRunner(testCase: self).run(Features.openAndProcess)`.
4. Put `// @generated by star-gherkin-gen — do not edit.` and
   `// source-hash: <sha256 of every input file, sorted by path, concatenated>` at the top of
   every generated file.

Commit the generated files, as Preffect does. A fresh clone builds without Ruby, and only
someone editing a `.feature` needs it.

### Placeholder values

Each runner resolves a `{name}` placeholder in this order:

1. env var `STAR_GHERKIN_<UPPER_NAME>` (on XCUITest, set `TEST_RUNNER_STAR_GHERKIN_<NAME>`
   for xcodebuild, which strips the `TEST_RUNNER_` prefix)
2. the per-client override in `params.json`
3. the default

Relative paths resolve against the repo root. Swift finds the root from `#filePath`. Kotlin
uses `rootProject.projectDir.parentFile`, passed in as a system property from the Gradle task.

**Copy the sequence to a fresh temp dir per run.** Star derives its temp and output paths from
the input directory name, so re-processing a dir in place picks up the last run's state (see
`cli-behaviour-verification` in project memory). The `I open the sequence` step does the copy,
and every runner works on the copy.

## Per-client runners

All three share one shape: a `methodMap: [StepAction: (Runner) throws -> Void]`, a
`run(feature)` that reports each step by name, and a `noMethodForStep` error that lists what
is implemented. Steps use generous explicit waits and never sleep for a fixed time.

### 1. cli: `cli/Tests/GherkinTests`

- Add a `.testTarget(name: "GherkinTests", dependencies: [.product(name: "StarGherkinKernel", package: "StarGherkin")])`
  to `cli/Package.swift` (add the local package dependency `../gherkin/StarGherkin`). It does
  **not** need `@testable import star`. It is black-box: it runs the built binary.
- Find the binary from the test bundle's products directory (the usual SwiftPM
  `productsDirectory` helper, which works on macOS and Linux). Let `STAR_CLI_PATH` override
  it.
- Steps:
  - `openSequence` copies to temp.
  - `processEveryFrame` runs `star -l info <copy> <outdir>` and requires exit 0.
  - `outputFramesWritten` counts files in `<outdir>`.
- Read `cli-xcodeproj-ld-broken` in project memory. Use `swift build`/`swift test` only.
- Read `adding-tests-per-target` in project memory. Anything importing StarDecisionTrees needs
  `-I<path>` joined with no space. This target shouldn't import it at all, so keep it that way.

### 2. macOS gui: `gui/starUITests` (XCUITest)

The existing target holds only Xcode template stubs. **Delete** `starUITests.swift` and
`starUITestsLaunchTests.swift`, then add `GeneratedFeatureUITests.swift` +
`GuiFeatureRunner.swift`. Registering a new file in `gui/star.xcodeproj/project.pbxproj`
takes **four** entries: `PBXBuildFile`, `PBXFileReference`, the group's `children`, and the
`starUITests` Sources build phase. Copy the stubs' existing entries (ids `D386FA2C…`,
`D386FA2D…`) as the template. Then:

- Link `StarGherkinKernel` into `starUITests` as a local package product. Mirror how the
  project already references StarCore. Read `adding-tests-per-target` first: the gui module is
  `Star` (capital S), and `starTests` needed a deployment target and include path fixed.
  `starUITests` will likely need the same (`MACOSX_DEPLOYMENT_TARGET` 15.0).
- **Add `starUITests` to the `star` scheme's `<Testables>`.** Today it lists only `starTests`
  (`gui/star.xcodeproj/xcshareddata/xcschemes/star.xcscheme`). Without this, `-only-testing`
  matches nothing and xcodebuild **exits 0**.
- **App-side test seam.** There's no launch-argument handling in `gui/star` today, and opening
  a sequence goes through `NSOpenPanel` (`InitialView.swift:240-324`). Add one: at startup, if
  `UserDefaults.standard.string(forKey: "StarUITestOpenSequence")` is set (XCUITest passes
  `launchArguments += ["-StarUITestOpenSequence", path]`, which lands in the argument domain),
  call `viewModel.startup(withNewImageSequence: path)`, the same call `InitialView.swift:324`
  makes. That path puts the sequence in `.edit` mode. Sequences opened any other way start in
  `.scrub`, where **every sheet silently fails to show**. Read `gui-sheet-attachment-trap` in
  project memory before touching the process-all flow (`ImageSequenceViewModel.processAll()`
  → `preProcessingRenderPromptShowing` → `beginProcessing()`).
- **Accessibility identifiers.** `gui/star` has zero today. Add `.accessibilityIdentifier`
  only to what the steps touch: the process-all control, the pre-processing prompt's buttons,
  and a "processing finished" indicator. Don't expose a sleep-then-check. Expose state the test
  can wait on, e.g. an identifier on the progress text whose value reads `done` or the frame
  count.
- `XCUIApplication().launchEnvironment["STAR_RUN_MARKER_DIR"] = <fresh temp dir>`, so a stale
  run marker can't raise the crashed-run critical alert over the window. That env var is
  honoured in `StarCore/Sources/StarCore/RunMarker.swift:494`; see `gui-alert-verification`
  in project memory.
- **Verify early: can the UI-test runner process read the output directory?** `star.entitlements`
  has no app-sandbox, so the app can write anywhere. If the runner can't list the files,
  assert through an app-exposed element instead, e.g. an identifier carrying the written count.
  Check this first, before writing the other steps.
- **CI build:**
  `xcodebuild test -project gui/star.xcodeproj -scheme star -only-testing:starUITests`. Don't
  use `-target Star`, and omit `-destination` (see `gui-worktree-build` in project memory).
  UI tests need the runner signed to run locally, so expect to pass
  `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` rather than
  `CODE_SIGNING_ALLOWED=NO`, and confirm on the runner.
- The build needs `gui/videos/*.mp4` (`gh release download ci-assets`) and ffmpeg/ffprobe in
  `external_binaries/bin`. Copy both from the `macos-signed-release` job in `cli.yml`. Note
  that `ffmpeg.yml` is a reusable workflow, and its macOS artifact is only produced when
  called.
- A fresh worktree needs the gitignored opencv, StarDecisionTrees and gui/videos symlinks (see
  `gui-worktree-build`). **Remove the `gui/videos` symlink before committing.** It shows up as
  untracked.

### 3. Compose desktop: `star-desktop` `gherkinTest` source set

- Add a source set `gherkinTest` and a `Test` task `gherkinTest`
  (`useJUnitPlatform()`, `dependsOn` nothing heavy). Add
  `compose.desktop.uiTestJUnit4` to its dependencies. Keep it **out of** `./gradlew test`,
  because the `build-test` matrix job runs that on ubuntu/windows without a `stard`. Forward
  `star.stard.path` and the repo-root property to the test JVM, and set
  `STAR_RUN_MARKER_DIR` the way `tasks.test` already does.
- `stard` location: `-Dstar.stard.path=...` is already the documented dev override
  (`engine/DaemonProcess.kt:174-208`).
- Drive the **real root**: `runComposeUiTest { setContent { StarApp(vm) } }`, with
  `vm = AppViewModel(scope, autoOpenPath = <temp copy>, autoMode = "edit", autoFrame = null)`.
  That constructor is the existing `./gradlew run --args=` dev hook (`Main.kt:38-45`), so
  **no new app seam is needed to open a sequence**. Don't use `StarMenuBar` (it needs a
  `FrameWindowScope`). If a step needs a menu action, call the `AppViewModel` method that the
  menu item calls.
- `testTag`s: star-desktop has zero. Add `Modifier.testTag(...)` to the same three things as
  the Mac gui: the process control, the prompt's buttons, and the finished indicator. Wait with
  `waitUntil(timeoutMillis = …) { onAllNodesWithTag(...).fetchSemanticsNodes().isNotEmpty() }`.
- Processing runs in `stard` on real threads, not on the test clock. Expect to need
  `mainClock.autoAdvance = true` (the default) plus real-time `waitUntil`. Don't use
  `runTest`'s virtual time for the processing wait.
- **`stard` in CI:** the packaging jobs that build it are `if: github.event_name != 'pull_request'`,
  so PRs never get a stard from them. The pilot's desktop jobs must build stard themselves.
  Copy the build steps from `linux-package`, `windows-package` and `macos-signed` in
  `kotlin-client.yml`, including the Windows MSVC 14.40 pin. Expect Windows to be the slowest
  leg.

## CI: `.github/workflows/gherkin.yml`

A new workflow, on the same triggers as `cli.yml`, plus `paths:` that cover
`gherkin/**`, `cli/**`, `gui/**`, `star-desktop/**`, `StarCore/**` and the workflow itself.
Jobs:

1. **`generate-check`** (ubuntu-24.04):
   `ruby/setup-ruby` → `gem install cucumber-gherkin -v <pin a current version>` →
   build and run `star-gherkin-gen` → `git diff --exit-code`. Swift on Linux is already proven
   by `cli.yml`'s `SwiftyLab/setup-swift`. This is a *real* regeneration, stronger than
   Preffect's hash-only check. It is safe only because the generator normalises away
   parser-version differences, so confirm the iMac's 9.0.0 and CI's current gem produce
   byte-identical output. If they don't, fix the normalisation; don't drop the check.
2. **`cli-linux`, `cli-macos`**: reuse `cli.yml`'s setup and caches (same cache keys), then
   `swift test --package-path cli --filter GherkinTests`.
3. **`mac-gui`** (macos-15): Xcode latest-stable, caches, ci-assets, ffmpeg, then
   `xcodebuild test … -only-testing:starUITests`. Upload the `.xcresult` with
   `if: always()`. Its screenshots are the only evidence for a GUI failure.
4. **`desktop-linux`, `desktop-windows`, `desktop-macos`**: build stard, then
   `./gradlew gherkinTest -Pstar.stard.path=…`. Upload test reports with `if: always()`.

Refactoring the duplicated setup into reusable workflows is **out of scope** for the pilot.
Note what you duplicated in the PR so it can be collapsed later.

## Vacuous green: every leg must prove it ran

Preffect's worst failure was green runs that executed nothing. Each leg ends with a check that
fails the job when the count is wrong:

- **xcodebuild:** grep the log for `Executed 1 test` (match the exact count you expect) and
  zero skipped. The exit code alone is not proof.
- **swift test:** check that the output names `testOpenAndProcessFeature` and reports it
  passed.
- **Gradle:** parse `build/test-results/gherkinTest/*.xml` for `tests="1"` and
  `skipped="0"`.
- Each runner's `run(feature)` also fails when the feature has zero steps. A test that skips
  for missing setup (like Preffect's `XCTSkip` on absent credentials) is **forbidden** here.
  Missing setup is a failure.

## Traps already paid for (project memory has the details)

- `cli/star.xcodeproj` can't link under the current Xcode. Build the cli with `swift build`.
- `xcodebuild -target Star` fails with bogus module errors. Always use `-scheme star`.
- New gui test files need the four pbxproj entries. One missing entry means the file never
  compiles and the test silently doesn't exist.
- The iMac is x86_64 with gherkin 9.0.0 on system Ruby. An Apple Silicon Mac (a move is
  planned) won't load that gem, so the generator's discovery and `--format` sniffing must
  handle a Homebrew-Ruby `cucumber-gherkin` too. Document `gem install cucumber-gherkin` in
  `gherkin/README.md`.
- Don't gate or defer work on this Mac's load average or power; neither is a constraint.

## Deliverables

1. Everything under `gherkin/` above, generated files committed, plus a short
   `gherkin/README.md`: how to add a feature, how to add a step (edit `steps.json`,
   regenerate, implement in each client's `methodMap`), and how to run each client locally.
2. The three runners and the minimal app seams: the gui launch argument, gui accessibility
   identifiers, desktop test tags.
3. `.github/workflows/gherkin.yml`, green on a PR to `develop`, with the red-on-purpose proof
   described under Goal.
4. A short report back covering:
   - the measured output count per client
   - wall-clock time per leg
   - anything here that turned out wrong, especially UI-test runner file access and code
     signing
   - the parser-version diff result

## Non-goals

More features, Cucumber Expressions or regex steps, Scenario Outlines, suites or test groups,
reusable-workflow refactors, iOS or Android, and black-box driving of installed packages.
