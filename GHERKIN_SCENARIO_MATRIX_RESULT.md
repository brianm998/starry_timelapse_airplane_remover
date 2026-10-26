# Gherkin scenario matrix: result and Phase 0 findings (2026-10-16)

Written for the PR description. Numbers are from the iMac Pro (18 cores, 128 GB) unless a CI run is named.

## What runs locally, all green

| feature | cli | desktop | mac gui |
|---|---|---|---|
| autoSkyOnlyTiff16 | pass 43 s | pass | pass 311 s |
| autoHorizonJpeg | pass 46 s | pass 79 s | pass 643 s |
| autoHorizonVideo | pass 96 s | pass | pass 673 s |
| autoHorizonTiff16 | pass 102 s | pass | pass 562 s |
| autoMovingTiff16 | blocked: dataset not chosen | blocked | blocked |
| selectiveHorizonTiff16 | pass 193 s | pass | pass 1202 s |
| autoSelectiveHorizonTiff16 | pass 310 s | pass | pass 1166 s |
| autoHorizonJpegVideoOut | pass 73 s | pass | pass 529 s |

None of this has run on CI: the new datasets are not uploaded, and no branch is pushed.

## Findings that changed the runners

* **Auto selective differs by client.** On the desktop every frame ends at "outliers ready for review" (0/N complete, run over),
  and the user finishes with Render All Frames, which writes the finals without moving the complete count; the runner clicks it
  (`render.all.frames`). The mac gui and the cli write the finals by themselves, and the mac gui's progress line never reads N/N for
  it, so its runner watches the disk (outlier data, then the finals).
* **The GUI reads the machine's real preferences** (`$HOME/.star.userprefs.json`). A "don't ask me again" answered once on this
  Mac skipped the pre-processing prompt, so `I render the output video` produced no video. The GUI runner now sets `HOME` to a
  scratch directory, as the desktop runner already did with `user.home`.
* **A stale run marker covers the desktop UI with an alert** that swallows every click. The Gradle task now deletes
  `build/run-markers` first, and the runner retries a startup click that did not take.
* **The sandboxed UI-test runner can only write inside its own container**, and XCTest records an issue for a FileManager error
  even under `try?`. Artifacts go to `~/Library/Containers/com.star-guiUITests.xctrunner/Data/tmp/gherkin-artifacts`, which the
  workflow uploads, and every copy is guarded by an existence check.

## Phase 0: why the GUI legs are slower than the cli

Pilot run `38656452448` (macos-15 runners): cli 244 s, XCUITest 1231 s for the same 19 frames. Locally the same feature takes
46 s on the cli and 643 s in the GUI. In the CI log the GUI showed 0/19 complete for 19 minutes, then 17 more frames in one
minute: everything finishes together, so the time is in the shared stages, not in the end.

Sampling the running app (`sample`, 10 s) at the start of processing found two causes, one in the test and one in the product:

1. **Test artefact (fixed).** About half of the main thread's busy time was XCUITest answering the runner's own accessibility
   queries (`XCTElementQuery matchingSnapshots`): the runner polled `processing.progress` once a second with a query over the whole
   element tree. A query that waits too long also fails the test outright ("Timed out while evaluating UI query"), which is what
   killed the 16-bit TIFF features. The runners now watch the output directory and ask the UI only once the disk says the run is over.
2. **Product behaviour (reported, not changed).** A large share of the CPU is
   `FrameViewModel.refreshFrameHorizonOverlay` → `FrameHorizonProcessor.loadHorizonThumbnailOverlay` →
   `CombinedHorizonDetector.extractHorizonY`, and `refreshHorizonOverlay` → `loadOrCreateHorizonMask`: GUI-only work that redraws
   the horizon overlay on every frame as horizons are produced, next to the pipeline's own random-walker horizon
   (`gaussSeidelWithData`). In that sample `extractHorizonY` alone was ~36% of the busy samples. Users pay for this too; it is a
   candidate for debouncing or for skipping until the run ends. Not touched here, per the plan.
3. The GUI process peaked at 44.7 GB footprint on the 16-bit TIFF sequence (4.2 GB on JPEG). That is what a 7 GB runner will
   struggle with: expect the memory gate to throttle the GUI TIFF features there.

Not measured: Metal on the paravirtualised runner GPU, the keypoint divisor the desktop macOS leg pins, and whether the
`earth alignment` stage differs between clients.

## Thresholds

`removal_tools/thresholds.json`, with the measurements beside each value. Measured on the cli only: automatic changes
95.4–99.5% of pixels (mean brightness ratio 0.982–0.996, no black or saturated output); selective changes 0–0.33% of pixels and
17 of 19 frames. They separate the two modes by two orders of magnitude, but they have not been measured on the other legs.

## Not done

* Three consecutive green CI runs, and per-job times from them.
* Thresholds re-measured on ubuntu, windows and the GUIs (run with `STAR_GHERKIN_REPORT_ONLY=1`).
* Build once, share the products: the workflow builds per job. Worth doing for the mac gui and the Windows `stard`.
* The moving-camera dataset (frames to be chosen) and the three dataset uploads.
* The macOS GUI encoder is still separate from `VideoExport` (two encoders): a follow-up.
