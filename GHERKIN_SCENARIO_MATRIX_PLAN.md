# Gherkin: eight scenario features across every client

Instructions for the agent who builds this. The goal: eight `.feature` files, each covering one
combination of horizon / camera motion / input type / clean method / output video, running on
every client (cli, macOS gui, Kotlin desktop). Each ends by validating the output. CI runs them
on a pushed branch until they're reliably green, and only then do they merge to `develop` as part
of CI.

**Read first:**
- `gherkin/README.md`: the corpus, the generator, the runners and the vacuous-green guards.
- `test_data/README.md` and `test_data/datasets.json`: the dataset manifest, `fetch.sh` and the
  `data:` placeholders.
- `GHERKIN_REMOVAL_VALIDATION_PLAN.md`. A later agent builds that; this plan must leave room for
  it (see "Output validation").
- Project memory: `gui-worktree-build`, `adding-tests-per-target`, `gui-sheet-attachment-trap`,
  `cli-xcodeproj-ld-broken`, `i18n-architecture`, `removal-validation-oracle`.

## Decisions already made (by Brian, 2026-10-15)

- **The eight combinations** below are the whole set. Don't add the other 40.
- **The cli gains video input and output-video rendering**, so all eight features run on all three
  clients. (Today the cli has neither: nothing under `cli/Sources` calls ffmpeg.)
- **The moving-camera feature uses one of Brian's real panning sequences**, not a synthetic pan.
  Ask him which one (see "Stop and ask Brian").
- **Work on a branch, push it, and iterate on CI until it's green.** Merge to `develop` only after
  that.

## The eight features

All are tagged `@cli @mac-gui @desktop`. Names are lowerCamelCase with a matching `@tag`, one
Scenario per file, as `gherkin/README.md` requires.

| # | feature | horizon | camera | input | clean method | output video | dataset |
|---|---|---|---|---|---|---|---|
| 1 | `autoSkyOnlyTiff16` | no | static | 16-bit TIFF | auto | no | `a7sii_10_sky_tiff16` |
| 2 | `autoHorizonJpeg` | yes | static | JPEG | auto | no | `a7sii_10` (exists) |
| 3 | `autoHorizonVideo` | yes | static | video | auto | no | `a7sii_10_h264` |
| 4 | `autoHorizonTiff16` | yes | static | 16-bit TIFF | auto | no | `a7sii_10_tiff16` |
| 5 | `autoMovingTiff16` | yes | moving | 16-bit TIFF | auto | no | `moving_<name>_tiff16` |
| 6 | `selectiveHorizonTiff16` | yes | static | 16-bit TIFF | selective | no | `a7sii_10_tiff16` |
| 7 | `autoSelectiveHorizonTiff16` | yes | static | 16-bit TIFF | auto selective | no | `a7sii_10_tiff16` |
| 8 | `autoHorizonJpegVideoOut` | yes | static | JPEG | auto | yes | `a7sii_10` |

- **The existing `openAndProcess.feature` is row 2.** Replace it with `autoHorizonJpeg`, and
  delete the old file. The generator removes its generated tests.
- **Clean-method names:**

  | here | cli | `CleanMethod` | gui name |
  |---|---|---|---|
  | auto | `-c automatic` | `.automatic(false)` | |
  | selective | `-c selective` | `.selective` | |
  | auto selective | `-c automatic:true` | `.automatic(true)` | "Selective Auto Clean" |

  `.automatic(true)` was fixed in `1b2cb327`; it used to restore the airplanes.
- **Row 3's frame format is a feature param** (`frame_format`, default `tiff16`), and so is its
  video. Brian listed "different types of video, exported to TIFF and JPEG" as the input
  dimension but chose one video row. Keep it parameterised, so adding a variant later (ProRes, or
  `jpeg` frames) is a new feature file and no new code.

Shape of a feature (row 6 shown; the others differ only in their `Given` lines and data):

```gherkin
@selectiveHorizonTiff16 @cli @mac-gui @desktop
Feature: selective clean of a static 16-bit TIFF sequence with a horizon

  Scenario: Process a static 16-bit TIFF sequence with a horizon in selective mode
    Given the frames have a horizon
      And the camera is static
      And the clean method is selective
      And I open the sequence {sequence}
     When I process every frame
     Then the run used the requested settings
      And every input frame has a processed output frame
      And the output frames keep the input's format, size and bit depth
      And the output frames were processed in selective mode
      And Star reported no problems
```

Row 3 uses `And I import the video {video} as {frame_format} frames` in place of the open step.
Row 8 adds `And I render the output video` after processing, and
`And the output video has one frame per output frame`.

## Current state you're building on (measured 2026-10-14/15)

**Last green gherkin run** (`38656452448`, branch `claude/gherkin-speed-test-data-8b2cf1`, 19 ×
12 MP JPEG frames, one feature):

| leg | job | Gherkin step |
|---|---|---|
| cli (ubuntu-24.04) | 6 min | 345 s |
| cli (macos-15) | 4 min | 244 s |
| mac gui (macos-15) | 28 min | 1624 s (the XCUITest itself 1231 s, already a Release build) |
| desktop (ubuntu-24.04) | 8 min | 198 s |
| desktop (windows-2022) | 19 min | 269 s (the `stard` build is 507 s) |
| desktop (macos-15) | 40 min | 2233 s; needed a retry, and has a keypoint-divisor pin |

**The macOS GUI legs process the same 19 frames about 5× slower than the cli on the same runner
type.** With eight features that's where the time goes. Phase 0 is about it.

**The three runners don't test the same thing today:**
- cli: no flags, so `.automatic(false)`, horizon on, static.
- mac gui: clicks horizon yes, static, select-horizon no, then Start with the toggles at their
  defaults, which is `.automatic(false)`.
- desktop: `autoMode = "edit"`, which skips the startup prompts, so it processes with
  `SessionRepository.kt:96`'s default, **`CLEAN_SELECTIVE`**.

The new `the run used the requested settings` step exists so that can't happen silently again.

## How each client sets each dimension

Mapped from the code on 2026-10-15; file:line references are to that state.

**Horizon** (`Config.horizonDetectionEnabled`, default true, `Config.swift:848`; off means no
horizon or earth stages at all):
- **cli:** `--no-horizon` (`StarCli.swift:190`).
- **mac gui:** startup `HorizonView`. "Yes" is `startup.horizon.yes` (`StartupView.swift:107`);
  "No" has **no id** (`:76`).
- **desktop:** `StartupPrompts.kt:90-96` calls `startupAnswerHorizon`. **No test tags.**

**Camera** (`Config.tripodHeadWasMoving`):
- **cli:** `--moving-camera` (`StarCli.swift:196`).
- **mac gui:** `MovingView`. "Static" is `startup.moving.static` (`:174`); "Moving" has no id.
  - With moving + horizon, the next screen is `SelectMovingHorizonsView` (a horizon-count
    stepper), which has no ids.
  - With static + horizon, it's `SelectHorizonView` (`startup.selecthorizon.no`).
  - With no horizon, it goes straight to `RemovalView`.
- **desktop:** `MovingPrompt` (`StartupPrompts.kt:98-107`); the next step comes from
  `stepAfterCameraMotion` (`AppViewModel.kt:147-151`). No tags.

**Clean method:**
- **cli:** `-c`.
- **mac gui:** only through `RemovalView`'s toggles (`StartupView.swift:373-411`), none of which
  have ids:
  - airplanes + satellites + meteors → auto
  - airplanes + satellites, meteors off → auto selective
  - airplanes on, satellites off → selective
- **desktop:** the same mapping in `removalCleanMethod` (`StartupPrompts.kt:369-375`).
  - The settings dialog also has an Automatic / Auto-selective / Selective control
    (`ProcessingSettingsDialog.kt:134-151`).
  - Drive the startup prompts, as a user does, not the settings dialog.
- **Selective output:** in every client, "process all" writes the final images with no further
  user action (`MergeOp.swift:64-75`).

**Video input:**
- **cli:** none. You add it.
- **Shared decoder:** `StarCore/Sources/StarCore/VideoConvert.swift` `decodeVideo(named:format:)`.
  - It writes `<video dir>/<sanitized name>/image_%04d.<tiff|jpg>` and stores `VideoInfo` in the
    config.
  - Formats (`FrameDecodeFormat.swift`): `tiff16` (default, `rgb48le`), `tiff8`, `jpeg` with
    quality 1–100.
- **ffmpeg/ffprobe lookup** (`ToolPaths`, `ToolInstallation.swift:21-90`): `$STAR_FFMPEG_DIR`,
  then beside the executable, then `external_binaries/bin` from `.build`, then `PATH`.
- **mac gui:**
  - "Load Video" opens an `NSOpenPanel` and calls `startupWithVideoToProcess`
    (`InitialView.swift:278-317`).
  - That raises `VideoImportSheetView`: format radios, quality slider and Import, all **without
    ids**.
  - **There is no UI-test hook for opening a video.**
- **desktop:**
  - `openVideo(path)` raises `VideoImportDialog`, which has no tags, then `Session.OpenVideo`.
  - Auto-opening a video file *skips* the dialog and uses TIFF16 (`AppViewModel.kt:873`). So
    the runner must go through `openVideo` and the dialog, to choose the format the feature asks
    for.

**Output video:**
- **cli:** none. You add it.
- **mac gui:**
  - The pre-processing prompt's "Yes" has **no id**; "No" is `prompt.pre.no`.
  - Yes → after processing, `renderVideoAutoStart` → `RenderVideoSheetView` → ffmpeg glob encode
    (`ImageSequenceViewModel.swift:3385-3440`).
  - The output is `<outputPath>/<basename>.<muxer ext>`.
- **desktop:**
  - The same prompts are in `RenderPromptDialogs.kt`.
  - `startRender` calls `Export.Video` (`AppViewModel.kt:378-408`).
  - The encoder is `daemon/Sources/stard/VideoExport.swift` (133 lines, imports only Foundation
    and StarCore), using an ffmpeg concat list with a per-entry `option framerate`. Read project
    memory `export-video-frames` for why that matters.
- **Defaults when the input isn't a video** (`Config.swift:819-840`): 30 fps, ProRes,
  `yuv422p10le`, `.mov`.

**Existing seams:**
- mac gui identifiers: `startup.horizon.yes`, `startup.moving.static`, `startup.selecthorizon.no`,
  `startup.removal.start`, `prompt.pre.no`, `processing.progress` (label
  `<complete>/<total>/<running|idle>`).
- desktop tags: `process.frames`, `processing.progress` (same format in `stateDescription`),
  `settings.process`, `prompt.pre.no`.
- mac gui launch argument: `-StarUITestOpenSequence <dir>` (`ViewModel.swift:96-127`).
- desktop: `AppViewModel(autoOpenPath, autoMode, …)`. **Any non-null `autoMode` suppresses the
  startup prompts** (`AppViewModel.kt:1215`).

---

## Phase 0: find out why the GUI legs are 5× slower than the cli

Before adding seven features, find out why the same 19 frames take about 1231 s in the mac gui
XCUITest and about 2233 s in the macOS desktop leg, against about 244 s for the cli on the same
runner type.

Candidates to measure, not assume:
- **Preview and thumbnail writing.** The GUIs write previews; the cli doesn't.
- **The memory gate** on a 7 GB runner. See memories `memory-gate-shared-machine` and
  `memory-gate-ledger-realization`.
- **Keypoint concurrency** ("frames cap 3"), and the keypoint divisor the desktop leg had to pin.
- **The XCUITest polling interval.**
- **Metal on a paravirtualised runner GPU** vs the cli's path.
- **`earth alignment`.** The gui sets `allowEarthAlignment = removeCars`.

Read the per-frame timing in the logs of run `38656452448`, and run the cli with exactly the
config the GUI ended up with (its saved `config.json`).

- **Fix it if the cause is a test-environment artefact** (polling, a GUI-only option the features
  don't need, a runner-size misjudgement).
- **Don't change Star's behaviour for users to speed up tests.** If the cause is real GUI work
  users also pay for, report it and move on.

Report the numbers either way. They decide whether the time budget below holds.

## Phase 1: datasets (needs Brian for the moving sequence and all uploads)

Build each archive with `test_data/build_archive.sh`, add it to the manifest, and **ask Brian to
upload it**. The agent can't upload, as `test_data/README.md` explains. Then check every URL
anonymously.

| dataset | how to make it |
|---|---|
| `a7sii_10_tiff16` | All 19 `a7sii_10` frames: `magick LRT_000NN.jpg -depth 16 -compress lzw LRT_000NN.tif`. About 20 MB a frame (measured), about 380 MB total. The content has only 8-bit precision; it tests the 16-bit TIFF *format* path, which is what row 4/6/7 need. Say so in the description. |
| `a7sii_10_sky_tiff16` | The same frames cropped to sky only: full width, top 1800 rows (`-crop 4240x1800+0+0 +repage`). The horizon's highest point, the mountain on the right, sits at about row 2020, so 1800 leaves margin. **Look at every cropped frame** and confirm there's no ground before using it. |
| `a7sii_10_h264` | `ffmpeg -framerate 30 -start_number 80 -i LRT_%05d.jpg -c:v libx264 -pix_fmt yuv420p -crf 12 a7sii_10.mp4` from the 19 JPEGs, at full resolution. Confirm with ffprobe that it has 19 frames. If libx264 refuses 4240×2832 at the default level, set `-level 6.1` rather than scaling. |
| `moving_<name>_tiff16` | **Ask Brian which panning sequence and which 15–20 frames.** Candidates from memory: the a7 IV aurora pan (`LRT_11_30_2024-a7iv-1-aurora-topaz`). Avoid the a9-1 aurora: its ground is 94–99.7% black (memory `a9-black-ground-earth-alignment`), so it tests a known failure, not the moving path. Downscale to about 12 MP if larger (42 MP sources), convert to 16-bit LZW TIFF, and keep the horizon in frame. |

`a7sii_10` (JPEG) already exists. The existing committed `test_data/test_a7sii_10` stays where it
is; that's another plan's business.

## Phase 2: generator and step vocabulary

**Per-feature params.**
- `params.json` gains `"features": { "<feature>": { … } }`.
- Resolution order: env `STAR_GHERKIN_<NAME>`, then that feature's client override (if you need
  one), then that feature, then the client, then `default`.
- The generator validates every `data:` reference against the manifest, as now.
- Per-client dataset lists are now derived from the features each client runs.

**CI matrix input.** The generator also emits `gherkin/generated/features-<client>.json`: the
features that client runs, as a JSON array. CI builds its matrix from it.

**New `steps.json` entries.** These are fixed text, not placeholders: an enumeration reads better
as distinct steps, and stays exact-match.

| case | text |
|---|---|
| `horizonYes` | `the frames have a horizon` |
| `horizonNo` | `the frames have no horizon` |
| `cameraStatic` | `the camera is static` |
| `cameraMoving` | `the camera is moving` |
| `cleanAuto` | `the clean method is automatic` |
| `cleanSelective` | `the clean method is selective` |
| `cleanAutoSelective` | `the clean method is auto selective` |
| `importVideo` | `I import the video {video} as {frame_format} frames` |
| `renderOutputVideo` | `I render the output video` |
| `usedRequestedSettings` | `the run used the requested settings` |
| `everyFrameOutput` | `every input frame has a processed output frame` |
| `outputKeepsFormat` | `the output frames keep the input's format, size and bit depth` |
| `processedAuto` | `the output frames were processed in automatic mode` |
| `processedSelective` | `the output frames were processed in selective mode` |
| `processedAutoSelective` | `the output frames were processed in auto selective mode` |
| `outputVideoMatches` | `the output video has one frame per output frame` |
| `noProblems` | `Star reported no problems` |

Remove `outputFramesWritten` (`{expected_outputs} output frames are written`); the count now
comes from the input. Keep `openSequence` and `processEveryFrame`.

**Ordering rule, enforced by the generator.** Every setting step (`horizon*`, `camera*`,
`clean*`) must come before the open or import step, and exactly one of each must be present.
Runners collect settings and apply them when the sequence opens, which is when the GUIs ask. A
feature missing one, or with a setting after the open, must fail generation, with file:line.

## Phase 3: cli video input and output video

Both are product features users will see, so make them properly.

**Video input**
- `star <video file> [<output dir>] [--frame-format tiff16|tiff8|jpeg[:<quality>]]`.
- When the positional input is a file with a video extension (use the desktop's list,
  `FileChoosers.kt:15`: `mov mp4 m4v avi mkv mpg mpeg`), decode with StarCore's `decodeVideo`
  into the same place the GUIs use, call `config.set(videoInfo:)`, then process that directory.
- The default format is `tiff16`, as in both GUIs.
- Fail clearly when ffmpeg/ffprobe can't be found, and name the `ToolPaths` search order in the
  message.

**Output video**
- Move `daemon/Sources/stard/VideoExport.swift` into StarCore, together with its daemon tests,
  and have the daemon call it from there. Keep the concat-list `option framerate` behaviour.
- `--render-video` renders the final frames after a successful run, using the config's video
  settings (the imported video's settings, else the `Config` defaults).
- `--video-path <file>` overrides the default path, which is the daemon's
  `defaultOutputPath(config:muxer:)`.
- Don't render if any frame failed.

**The mac gui keeps its own glob-based encoder.** Note it in the PR as a follow-up ("two
encoders"); don't unify it here.

**For both:**
- Help text goes in all 22 catalogues (`cli.*` keys; run `i18n/check.py`).
- cli unit tests cover argument parsing and the format option.
- The output-video feature covers the encode itself.
- Build the cli with `swift build`, never `cli/star.xcodeproj`, which can't link (memory
  `cli-xcodeproj-ld-broken`).

## Phase 4: runner support in each client

**Shared rule.** Every runner records the setting steps and applies them at the open or import
step, in that client's natural way. After processing, it hands the output validator the paths it
needs (below).

**cli runner**
- Settings map to flags: `--no-horizon`, `--moving-camera`, `-c automatic|selective|automatic:true`.
- Video import maps to the new video input and `--frame-format`.
- Output video maps to `--render-video`.
- Always pass `--keep-temp-files`, so the validator can read the run's `config.json` and the
  temp dir.

**mac gui runner**
- **Add identifiers** (`.accessibilityIdentifier`, nothing else about the views changes):
  - startup: `startup.horizon.no`, `startup.moving.moving`, the `SelectMovingHorizonsView`
    continue control, the removal toggles `startup.removal.airplanes/.satellites/.meteors/.cars`
  - `VideoImportSheetView`: `videoimport.format.tiff16/.tiff8/.jpeg` and `videoimport.import`
  - `prompt.pre.yes`
  - the render sheet's start control, and a render-finished indicator the test can wait on
    (an identifier whose value reads idle / running / done)
- **Clean method:** the runner sets the removal toggles to produce the requested method, using the
  mapping above.
- **Video:** add a launch argument `-StarUITestOpenVideo <path>` beside `-StarUITestOpenSequence`.
  It enters the same `startupWithVideoToProcess` path the open panel uses, so the import sheet
  appears, and the runner picks the format and clicks Import.
- **Output video:** answer `prompt.pre.yes`, then wait for the render indicator to read done.
  Don't sleep.
- Read memory `gui-sheet-attachment-trap` before touching any sheet. New pbxproj files need their
  four entries.

**desktop runner**
- **Stop using `autoMode = "edit"`.** It skips the startup prompts, which is why the desktop
  currently tests selective while the others test auto. Open with prompts showing and answer them.
- **Add `testTag`s** to every prompt control the steps touch: horizon yes/no, static/moving,
  select-horizon no, moving-horizons continue, the removal toggles, Start, the
  `VideoImportDialog` format radios and Import, and the pre-prompt Yes. Add a render-finished
  state as well.
- **Video:** call `openVideo(path)`, which shows the dialog, not auto-open, which skips it.
- **Output video:** answer the pre-prompt Yes and wait for the `VideoExportedEvent` path.
- **Check whether the macOS keypoint-divisor pin** (`STAR_GHERKIN_DESKTOP_KEYPOINT_DIVISOR`) is
  still needed after Phase 0.

## Phase 5: output validation

Every feature ends with the validation steps, and **all of them are checked by one tool, never
re-implemented per client**:
- `removal_tools/star-output-verify`, a standalone SwiftPM package following the repo's tool
  pattern (ArgumentParser + StarCore), using StarCore's image loading.
- `GHERKIN_REMOVAL_VALIDATION_PLAN.md` later adds `star-removal-verify` to the same package, and
  appends `Then the labelled airplanes are removed` lines to these same features. Leave both
  possible:
  - don't name your tool `star-removal-verify`
  - don't make features impossible to extend
- Runners call it as a subprocess with the run's paths and the expected settings.
- **XCUITest:** first check that the UI-test runner can launch a subprocess and read the output
  directory. If it can't, run it as a CI step after `xcodebuild test`, from paths the test writes
  to a known file. Keep the vacuous-green guard either way.

What each step checks:

| step | check |
|---|---|
| `the run used the requested settings` | The run's saved `config.json` has `horizonDetectionEnabled`, `tripodHeadWasMoving` and `cleanMethod` equal to what the feature asked for. Each runner finds that file for its client: cli `<temp>/config.json`; the GUIs wherever their `ConfigManager` saved it. Find out, don't guess. This is what would have caught the desktop testing selective. |
| `every input frame has a processed output frame` | One output per input frame, matched by base name. For video input, the inputs are the extracted frames, whose count must equal ffprobe's frame count of the source video. |
| `the output frames keep the input's format, size and bit depth` | Same extension, width, height, channels and bits per component as the input. TIFF16 stays 16-bit, JPEG stays 8-bit, and video frames match the chosen frame format. Every file decodes. |
| `…processed in automatic mode` | Every output frame differs from its input in most pixels (the median composite recomputes every pixel), and none is degenerate: mean brightness within a measured band of the input's, nothing all black, nothing saturated. |
| `…processed in selective mode` | Frames with no removal are unchanged except where Star painted: exactly equal for 16-bit TIFF input; for JPEG, only re-encode noise. Changed pixels are a small fraction of the frame, and the frames known to carry trails (e.g. `LRT_00092`) did change. |
| `…processed in auto selective mode` | Like automatic, plus the run's outlier data exists (`--keep-temp-files` on the cli). |
| `the output video has one frame per output frame` | Using ffprobe: the file exists where the client said it wrote it, its frame count equals the output frame count, its size equals the frame size, and its frame rate and codec are the expected ones (the defaults, or the imported video's). |
| `Star reported no problems` | cli: exit 0 and no warning lines. mac gui: no alert on screen at the end. desktop: the view model's warning list is empty. |

**Thresholds must be measured, never guessed.** Run every feature once in report-only mode (on all
legs), put the measured distributions in the PR description, set each threshold with clear margin,
and record the measurements next to it in a committed thresholds file. If passing and failing
cases overlap, change the check, not the number.

## Phase 6: CI

Restructure `.github/workflows/gherkin.yml` so wall clock stays at about 2 hours per full run.

**One job per (client, OS, feature).** Build each job's matrix from
`gherkin/generated/features-<client>.json`. Each job runs exactly one feature:
- `-only-testing:starUITests/GeneratedFeatureUITests/test<Name>Feature`
- `swift test --filter`
- `gradle --tests`

Its vacuous-green guard checks that exactly that one test ran and passed.

**Build once per client and OS, then share the result:**
- **mac gui:** `xcodebuild build-for-testing` once, upload the products and `.xctestrun`; each
  feature job runs `test-without-building`.
- **desktop:** build `stard` once per OS, upload it; the feature jobs download it. The Windows
  `stard` build is 9 minutes, so building it eight times would be the worst offender.
- **cli:** build once per OS if it's easy; the cli build is cheap enough to repeat if not.

**Datasets.** Each job fetches only the datasets its feature needs, through the existing cache.

**ffmpeg/ffprobe** for every job that imports or renders video, and for the validator: use the
`ffmpeg.yml` artifacts for that OS, and set `STAR_FFMPEG_DIR`.

**Runner limits.** GitHub's free tier runs at most 5 macOS jobs at a time. 8 features × (cli + gui
+ desktop) is 24 macOS jobs, so expect queueing. Rough estimate from the numbers above: about
2 hours of wall clock, dominated by the GUI legs. That's what Phase 0 can shrink.

**Timeouts.** Set per job from measured times plus margin. A hung GUI job must fail rather than
eat the six-hour limit.

**Triggers:**
- PRs to `develop`, and pushes to `develop`, with the existing path filters.
- `workflow_dispatch` with a `features` input (comma-separated) to run a subset while iterating.

**Artifacts.** Upload, with `if: always()`:
- every validator report
- the `.xcresult`
- Gradle reports
- the run's `config.json`

## Branch, CI and merge

1. Work on a branch from `develop`, and push it. If the push fails, tell Brian; don't work around
   it.
2. Open a **draft PR to `develop`**, and iterate until every job is green.
3. Then run the full suite **twice more** with no changes, via `workflow_dispatch` or a re-run.
   All three runs must be green: the GUI legs have been flaky before (the desktop macOS leg
   needed a retry).
4. Post per-job times from the green runs in the PR, along with the Phase 0 findings.
5. Merge to `develop` only after all that.

## Done means

- The eight feature files exist, `openAndProcess.feature` is gone, and the generated files are
  current.
- All 8 features × 3 clients × their OSes are green, three runs in a row.
- One deliberate breakage per category turns the right features red, with a readable validator
  report. Prove each once on a throwaway commit, then revert:
  - a clean-method mapping (e.g. the desktop's selective default)
  - a format break (8-bit TIFF16 output)
  - an output-video frame count
- The cli has `--frame-format` video input and `--render-video`, with help text in all 22
  catalogues and unit tests.
- `gherkin/README.md` is updated:
  - the new steps and the ordering rule
  - per-feature params
  - the validator
  - the CI matrix
  - how to run one feature locally on each client
- Phase 0's findings and the measured thresholds are in the PR and in project memory.

## Stop and ask Brian

- **Which moving sequence, and which frames.** Ask early, since dataset uploads need him too.
- **Every dataset upload.**
- Before changing anything about how Star processes for users to make a test faster or pass.
- If a feature can't be made reliable on a client, before dropping that client's tag.

## Not in scope

- The other 40 combinations.
- Video variants beyond the parameterised row 3.
- Removal-correctness checks: `GHERKIN_REMOVAL_VALIDATION_PLAN.md` adds those to these features
  later.
- Unifying the mac gui's video encoder with the shared one.
- Moving `test_data/test_a7sii_10`'s other consumers.
