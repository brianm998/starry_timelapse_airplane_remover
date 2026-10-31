# Gherkin features

One Gherkin corpus drives the same user flow through three Star clients, each run on GitHub
Actions (`.github/workflows/gherkin.yml`):

| Client | Tag | Driver | Runs |
|---|---|---|---|
| `star` cli | `@cli` | XCTest running the built `star` binary as a subprocess (`cli/Tests/GherkinTests`) | ubuntu-24.04, windows-2022, macos-15 |
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
  params.json                 placeholder values: { "default": {…}, "cli": {…}, "mac-gui": {…}, "desktop": {…}, "features": { "<feature>": {…} } }
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
* `gherkin/generated/features-{cli,mac-gui,desktop}.json`: the features each client runs, as a JSON array; CI builds its
  (client, OS, feature) matrix from it.

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

A UI feature (`@ui`) is the same, with the extra rules and the inline arguments (`I click "<id>"`) in `gherkin/ui/README.md`.

The generator fails, with file:line, on an unknown step, a placeholder with no default, a bad basename or
tag, a second scenario, or an unsupported construct. It deletes and rewrites every generated location each
run, so a deleted feature leaves no orphan test behind.

## The eight scenario features

Each combines horizon / camera motion / input type / clean method / output video, and every one runs on all three clients.

| feature | horizon | camera | input | clean | output video | dataset |
|---|---|---|---|---|---|---|
| `autoSkyOnlyTiff16` | no | static | 16-bit TIFF | auto | no | `a7sii_10_sky_tiff16` |
| `autoHorizonJpeg` | yes | static | JPEG | auto | no | `a7sii_10` |
| `autoHorizonVideo` | yes | static | video (`frame_format`, default `tiff16`) | auto | no | `a7sii_10_h264` |
| `autoHorizonVideoBackground` | yes | static | the same video, extracted in the background while it is processed | auto | no | `a7sii_10_h264` |
| `videoBackgroundIdentical` (cli only) | yes | static | the same, and then the video again extracted first | auto | no | `a7sii_10_h264` |
| `autoHorizonTiff16` | yes | static | 16-bit TIFF | auto | no | `a7sii_10_16bit` |
| `autoMovingTiff16` | yes | moving | 16-bit TIFF | auto | no | `moving_a7iv_1_aurora_tiff16` |
| `selectiveHorizonTiff16` | yes | static | 16-bit TIFF | selective | no | `a7sii_10_16bit` |
| `autoSelectiveHorizonTiff16` | yes | static | 16-bit TIFF | auto selective | no | `a7sii_10_16bit` |
| `autoHorizonJpegVideoOut` | yes | static | JPEG | auto | yes | `a7sii_10` |

Clean method names: *auto* is `-c automatic` / `.automatic(false)`; *selective* is `-c selective` / `.selective`;
*auto selective* is `-c automatic:true` / `.automatic(true)` ("Selective Auto Clean").

### Step vocabulary and the ordering rule

Setting steps: `the frames have a horizon` / `…have no horizon`, `the camera is static` / `…is moving`,
`the clean method is automatic` / `…selective` / `…auto selective`. Open steps: `I open the sequence {sequence}`,
`I import the video {video} as {frame_format} frames`. Then `I process every frame`, optionally
`I render the output video`, and the validation steps (`the run used the requested settings`, `every input frame has a
processed output frame`, `the output frames keep the input's format, size and bit depth`, `the output frames were
processed in automatic | selective | auto selective mode`, `the output video has one frame per output frame`,
`Star reported no problems`).

**Ordering rule, enforced by the generator:** exactly one horizon, one camera and one clean-method step, and exactly one
open or import step, with every setting step *before* the open step (with file:line when violated). Runners record the
settings and apply them when the sequence opens, which is when the GUIs ask. The runners also read the whole feature
first: a feature with `I render the output video` makes the cli pass `--render-video` and the GUIs answer Yes to the
pre-processing render prompt.

### Per-feature params

`params.json` has a `features` section keyed by feature name. A `{placeholder}` resolves from env
`STAR_GHERKIN_<NAME>`, then the feature's value, then the client's override, then `default`. The generator checks every
`data:` reference (including the feature ones) against `test_data/datasets.json`.

### Output validation

Every validation step is checked by one tool, never re-implemented per client: `removal_tools/` is a SwiftPM package
whose `star-output-verify` executable has a subcommand per check (`settings`, `frames`, `format`, `mode`, `video`).
Build it with `swift build -c release --package-path removal_tools`; runners find it at
`removal_tools/.build/release/star-output-verify` or `STAR_OUTPUT_VERIFY_PATH`. The `mode` thresholds live in
`removal_tools/thresholds.json`, with the measurements they were set from. `STAR_GHERKIN_REPORT_ONLY=1` makes the
`mode` checks print measurements and never fail: how thresholds are (re)measured. `STAR_GHERKIN_KEEP_SCRATCH=1` (cli)
keeps the scratch directory. The validator needs `ffprobe` (`STAR_FFMPEG_DIR`, as everywhere).

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

* **cli** (needs `opencv` and `StarDecisionTrees` built, as for any cli build, and the validator built). Like CI, one release compile;
  one feature is `--filter GherkinTests.GeneratedFeatureTests/test<Name>Feature`:
  ```bash
  swift build -c release --package-path removal_tools
  swift test -c release -Xswiftc -enable-testing --disable-swift-testing --package-path cli --filter GherkinTests
  ```
  (`-enable-testing` because the cli's other test target is `@testable import star`; `--disable-swift-testing` because the second Swift Testing pass starts `star`'s own `@main`, which rejects `-c release` and exits 1.) It runs the `star` beside the
  test bundle; a debug `swift test` works too but takes ~20 minutes on the 19-frame sequence. `STAR_CLI_PATH`
  overrides the binary. Never use `cli/star.xcodeproj`: it cannot link.
* **desktop** (needs a `stard`: `cd daemon && swift build -c release`):
  ```bash
  cd star-desktop && ./gradlew gherkinTest -Pstar.stard.path=$PWD/../daemon/.build/release/stard --tests '*autoHorizonJpegFeature'
  ```
  (also needs the validator built, as above).
  Offscreen (`java.awt.headless=true`); no Xvfb. Not part of `./gradlew test`.
* **mac gui** (needs `gui/videos/*.mp4`, ffmpeg in `external_binaries/bin`, and opencv/StarDecisionTrees):
  ```bash
  sudo automationmodetool enable-automationmode-without-authentication   # once per machine; hosted runners have it
  xcodebuild test -project gui/star.xcodeproj -scheme star -configuration Release ENABLE_TESTABILITY=YES -only-testing:starUITests/GeneratedFeatureUITests/testAutoHorizonJpegFeature \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  ```
  `-configuration Release` is what CI passes (the scheme's default stays Debug for development). Use `-scheme star`, never `-target Star`, and no `-destination`. Without automation mode `xcodebuild
  test` hangs at "Timed out while enabling automation mode".

## The seams the tests rely on

* gui: launch arguments `-StarUITestOpenSequence <dir>` (`ViewModel.openSequenceFromUITestArgument`) opens a sequence the way
  the open panel does, and `-StarUITestOpenVideo <file>` raises the video import sheet as "Load Video" does; both suppress
  the GitHub release check. Accessibility identifiers: `startup.horizon.yes/.no`, `startup.moving.static/.moving`,
  `startup.selecthorizon.no`, `startup.selectmovinghorizons.no`, `startup.removal.automatic/.autoselective/.selective/.groundalignment/.start`,
  `videoimport.format.tiff16/.tiff8/.jpeg`, `videoimport.import`, `prompt.pre.yes/.no`, `render.done`/`render.error`, and
  `processing.progress` whose label reads `<complete>/<total>/<running|idle>`.
* desktop: `Modifier.testTag`s with the same names for the startup prompts, the import dialog and the pre-prompt, plus
  `process.frames`, `settings.process` and `processing.progress` (same `stateDescription`). The runner does **not** use the
  `AppViewModel` auto-open hook (any `autoMode` skips the startup prompts, which is how the desktop once tested selective
  while the others tested auto): it opens through `openSequence` / `openVideo` and answers the prompts. A render is waited
  for on `AppViewModel.renderState`.

## Guarding against vacuous greens

`xcodebuild -only-testing:` matching nothing exits 0 having run nothing, so each CI leg also checks the
log: `Executed 1 test, with 0 failures` for xcodebuild, `test<Name>Feature` passed for swift test,
and `tests="1"` / `skipped="0"` in `build/test-results/gherkinTest/*.xml` for Gradle. Each CI job runs exactly one
feature, so the guard checks that exactly that test ran.

## Checking airplane and satellite removal

Features that must prove trails are actually gone use `trail_tools/` (a standalone SwiftPM package: `RemovalCore`,
the pure-Swift measurements, plus the `star-removal-verify` and `star-trail-inject` executables). **Status: four
features use the verifier (below; `removeAirplanes` on all three clients, the others on the cli); the thresholds are measured except the synthetic-data ones;
the synthetic features do not exist yet**; see `plans/GHERKIN_REMOVAL_VALIDATION_PLAN_RESULT.md`.

### Labels (`labels.json`)

Shipped inside each dataset archive. One polyline per trail, per frame, in full-resolution input pixels:
`{ "id", "class": airplane|satellite|meteor|other, "points": [[x,y],…], "width", "confirmed", "note" }`, plus an optional
`sky` polygon and `complete` (true = every trail in every frame is labelled). **Only `confirmed: true` objects are
checked, and only a person sets that.** Never mark an object confirmed from Star's own output.

* `tools/label-trails/index.html` is the labelling page: open it in a browser, pick a frame directory (browsers other than
  Safari can't show TIFF, so use same-named JPEG/PNG previews), click polyline points, set class/width/note, tick confirmed,
  export. It can load an existing `labels.json`; drafts are drawn orange, confirmed green.
* Labels must be drawn independently of Star. `OutlierGroupPaintData.json` is not ground truth.

### The verifier

```
star-removal-verify --input <dir> --output <dir> --labels labels.json \
    --expect "airplane=removed,satellite=removed" [--stars] [--unchanged-outside] [--base-output <dir>] \
    --thresholds gherkin/removal-thresholds.json [--baseline gherkin/removal-baseline.json --dataset <name> --clean-method <m>] \
    --report report.json --crops <dir> [--report-only]
```

Exit 0 = pass, 1 = failure, 2 = bad input (bad label, missing frame, wrong mode for `--unchanged-outside`).

* **Trail check:** per 50 px stretch, contrast = median(on-line, ≤ width/2) − median(two background bands, width/2+8 …
  width/2+26), reported as output/input. A stretch whose input contrast is under 5σ of its background is unmeasurable;
  over 20% unmeasurable length is a *label error*, neither pass nor fail.
* **Stars (`--stars`):** peaks > 10σ over a 32 px block-median background, flux = 7×7 sum − 49 × the 17×17 median; the
  median ratio and the fraction below 0.5 are judged as a distribution, inside `sky`, ≥ 40 px from any labelled object.
* **Unchanged outside (`--unchanged-outside`):** selective + lossless input + `complete` labels only (refused otherwise).
  Every connected component of changed pixels outside the footprint is reported, with a crop.
* **Why it was left in (`--temp <star_temp dir>`):** for every failing object, reads the run's outlier data (a `star -w --keep-temp-files` run;
  `selective` and `auto selective` keep it, `automatic` does not) and says which case it is: *not detected* (no outlier group touches the trail),
  *detected but discarded as dust*, *misclassified* (every touching group decided keep, with the classifier's score), or *painting/merge problem*
  (decided remove, yet still in the output). Diagnosis only: it never changes pass or fail, is skipped when nothing failed, and an error in it is a
  note in the report. The cli runner passes it whenever the run kept its temp directory.
* **Differential (`--base-output`):** for synthetic datasets, compares with Star's output on the un-injected base.
* Whole-frame golden images and PSNR/SSIM cannot be the check: the default mode recomputes every pixel and Metal vs CPU
  differ.

### Thresholds and the baseline

`gherkin/removal-thresholds.json`: each entry is `{ "value", "measured" }`; `value: null` means unmeasured, and the
verifier refuses to enforce until it is set (use `--report-only`). Never guess one; set it from measured distributions.

`gherkin/removal-baseline.json` ratchets known failures on **real** data, one entry per (dataset, frame, object, clean
method): still failing = pass and say so; failing but not listed = regression (fail); listed but now passing = **fail**
("remove it from removal-baseline.json"). Synthetic datasets get no baseline entries.

### Synthetic datasets

`star-trail-inject --base <clean 16-bit sequence> --out <dir> [--spec spec.json]` writes `base/`, `injected/` and a
`labels.json` (`confirmed: true`, exact by construction). Seeded and deterministic; run once to build a dataset, never at
test time. Satellites sweep SNR 3-100 (a Gaussian line, FWHM 1.5-3 px, constant along its length, some continuing collinearly into the next frame),
airplanes are twin lines with strobe dots tinted red/green/white (some run off the frame edge by 15% of their length), meteors are tapered and measured only.
`lengthScale` in the spec shrinks the trails to fit a small base (0.4 for 500x400).

`trails_synth_sky500`: a 500x400 sky-only region (x=0 y=425 of `a7sii_10_crop16`: the largest region with no labelled trail in any of the 19 frames) as `base/` and `injected/`, with
15 satellites, 4 airplanes and 2 meteors. Features `syntheticSatellites` and `syntheticAirplanes` (`@cli`) run Star on both with `the frames have no horizon`, `the clean method is automatic`
(`I process the injected sequence and its base`) and check that every injected trail is removed in the differential sense: the trail's contrast in (Star's output on `injected`) minus
(Star's output on `base`) is at most `removed_max` of its input contrast, and fewer than `differential_outside_max` of the pixels outside every footprint differ from the base output by more than 6 sigma.
Measured 2026-10-26: all 19 objects removed with a worst median ratio of 0.045; 3.4-5.0% of the outside pixels differ (the two outputs differ by alignment noise even with nothing injected);
12-14 s per feature.

**Why only `automatic`:** the same data in `selective` and `auto selective` leaves every injected trail in. `--temp` says why: the trails are *detected* (outlier groups of 200-1,500 px sit on them) but the classifier
decides keep, with scores of -0.0 to -0.94. The classifier's features are fractions of the frame, so a 150-350 px trail in a 500 px frame is far outside what it was trained on; cropping to keep pixel scale does not keep
the features in distribution (the plan assumed it would). A synthetic dataset for the classifier needs frames the size of real ones. Synthetic trails also have no real airplane's
brightness profile, so this is not a measure of the classifier's recall on real trails.

### Removal features (`removeAirplanes` on all three clients, the rest cli only)

| feature | clients | clean step | dataset | what it proves |
|---|---|---|---|---|
| `removeAirplanes` | cli, mac GUI, desktop | auto (`automatic:false`) | `a7sii_10` (JPEG) | every measurable labelled airplane is removed (median stretch ratio <= `removed_max`), stars preserved |
| `autoPreservationKeepsAirplanesOutJpeg` / `...Bit16` | cli | auto selective (`automatic:true`) | `a7sii_10` / `a7sii_10_16bit` | at least `removed_fraction_min` of the measurable airplanes are removed **and** the 42 pinned objects (`gherkin/removal-pins.json`) are; regression test for `1b2cb327` |
| `selectiveRemovesOnlyTrails` | cli | selective | `a7sii_10_16bit` | the pinned objects are removed, nothing outside the labelled trails changed (<= `unchanged_outside_max_area`), stars preserved |

These features use the scenario vocabulary: horizon, camera and clean-method steps before the open step (the ordering rule above), the dataset
from the feature's own entry in `params.json`, and `the run used the requested settings`. The removal-only steps are `the labelled airplanes|satellites
are removed`, `the stars are preserved` and `nothing outside the labelled trails changed`. Each `Then` runs `star-removal-verify` (from `trail_tools/`;
`removal_tools/`'s `star-output-verify` is the other, unrelated validator) as a subprocess with `--clean-method` taken from the run's own clean step,
fails with its summary plus the report and crop paths, and refuses to pass if the report did not check every labelled object of the class (or every
pin, or every frame). Selective is judged on the pinned objects only (`--pins-only`, BUG-004), automatic:true by the fraction removed plus the pins.
Reports and crops: the cli runner writes them to `removal-reports/<feature>/` (git-ignored; `STAR_REMOVAL_REPORTS` overrides, and CI points it into the
uploaded `gherkin-artifacts`); the GUI and desktop runners write `report-removal-*` beside the run, and `saveArtifacts` copies them out like the
validator's reports (the XCUITest runner is sandboxed: it can launch the verifier and read the output, but not write into the repo). The runners find the
verifier at `trail_tools/.build/release/star-removal-verify` (`STAR_REMOVAL_VERIFY` overrides; the Windows cli leg sets it).

The desktop runner opens a removal feature's session at DETECTION_STRONG by seeding the remembered detection type before the view model starts (an
unset one is MILD, Star's own default and the pins' is STRONG) and fails if it did not; other features keep the client's default. CI legs build
`trail_tools` only for these four features (the `if:` list on the "trail verifier" steps of `gherkin.yml`).

Why pins: per-object verdicts differ between platforms and the fraction removed cannot tell the pre-`1b2cb327` build (0.78) from the
fixed one (0.83), so the objects every healthy run removes are pinned (derived from Star's own output, not ground truth). Why the pass
rule is the median stretch ratio, why `selective` is not judged per object, and every threshold's evidence: `gherkin/removal-thresholds.json`
and `BUGS.md`. Local run: `swift test -c release -Xswiftc -enable-testing --disable-swift-testing --package-path cli --filter GherkinTests`
after `swift build -c release --package-path trail_tools` and `test_data/fetch.sh a7sii_10 a7sii_10_16bit`.

To add one: put the dataset (with `labels.json`) in `test_data/datasets.json`, give the feature its `sequence` under `features` in `params.json`, write the
`.feature` (setting steps, open, process, removal steps), run `gherkin/generate.sh`, and add the feature name to the `if:` list of the trail-verifier steps in `gherkin.yml`.

### Measuring (Phase 4)

`.github/workflows/removal-measure.yml` (manual) measures every dataset x clean method on ubuntu-24.04 and macos-15 and publishes a table plus
artifacts; `gherkin/measure-removal.sh <os> <out>` does the same locally (`MEASURE_FILTER=<substring>` runs a subset,
`STAR_TEST_DATA` points at the dataset cache). Thresholds in `removal-thresholds.json` must come from those tables.
