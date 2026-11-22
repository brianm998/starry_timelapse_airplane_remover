# star code audit: proposed tickets (2026-11-21)

**Filed 2026-11-21** after the owner approved all of them. B2 was modified: output quality matches the import
quality, plus an override slider that defaults to it.

| ticket | MASON | waits for |
|---|---|---|
| A1a picture loader / A1b forget deleted images | #837 / #838 | — / #837 |
| A2 / A3 / A4 / A5 | #839 / #840 / #841 / #842 | — / — / #839 / — |
| B4 / B1 / B3 / B2a / B2b | #843 / #844 / #845 / #846 / #847 | — / #843 / #844 / #844 / #846 |
| C1 / C2 / C3 / C4 | #848 / #849 / #850 / #851 | #837 / — / #842 / #842 |
| D1 / D3 / E1 | #852 / #853 / #854 | — |

D2 was not filed: MASON task t829 fixed the clipped "Processing complete" sheet on `develop` the same afternoon.
#841, #851 and #854 explore first; the rest carry settled plans.

Found afterwards, while checking the grey frames for file-descriptor exhaustion: **#869**, `homography.db`
connections are never closed, so every opened sequence or stard session leaks three descriptors. Filed as a
proposal; the owner approved it the same evening and it is queued (low priority).

Written for review: approve, dismiss or modify each ticket. Approved tickets become MASON tasks via the file-tickets
skill, each with its own plan and acceptance criteria.

**How this was done.** I read the code at `d43d17a5` and the gui's own diagnostic logs from today's two sessions
(`~/Library/Logs/star/Star-logs-2026-11-21-15-47-50.txt` and `…-16-10-39.txt`). I also looked at today's working
files under `/Volumes/sp/tmp` and screenshots 1 to 10. No gui was run: automated work never appears on this Mac's
screen, so none of the gui findings below has been reproduced in a running app. Nothing was built or tested.

**Not repeated here.** The core speed proposal (R1–R10) is merged. The 2026-10-29 parity plan is implemented
(its §9 log). The memory ledger running ~3× ahead of the real footprint is already known. Today it reserved
109 GB within 3 s of a start while 16 GB was in use.

---

## 1. The grey frames

### What the log shows

| time | what happened |
|---|---|
| 15:49 | First import of `09_16_2023-a7sii-1.mp4` as JPEG at quality 80. Processed by 15:51. |
| 16:04 | Sequence closed. |
| 16:06:12 | Same video re-imported into the same `/Volumes/sp/tmp`. Frames reused ("60 already there"), and `star_temp_…` reused, so it opened "complete" (screenshots 3–5). |
| 16:08:16–16:09:11 | Horizon painted. Screenshot 6 falls in the gap from 16:08:22 to 16:09:00. |
| 16:09:13 | `reference.tiff` saved. `continueToRemovalFromHorizonPainter` refreshes the horizon overlay of all 60 frames. |
| 16:09:25 | Start. `hasStaticReferenceHorizon false -> true` invalidates every stage of all 60 frames. Deleted: 60 merged-horizon masks (each one fires `horizonChangedClosure`, which bumps that frame's `reloadID`), 60 keypoint files, every homography and aligned image, and 60 output images. All frames go to `unprocessed`. |
| 16:09:28.54 | "all operations cancelled", which is the Stop. |
| 16:09:30–35 | Waiting ops are granted memory anyway and keep working: CPU 37 %, GPU 29 %, ledger 38 GB (ticket A2). |
| 16:09:53 | Start again. "build cancelled before it enqueued; dropping its 164 operations". Nothing runs (ticket A4). |
| 16:10:07 | Last line in the log: the app was quit. Relaunched 16:10:39 and re-imported at 16:11:39, which rebuilt `star_temp` from scratch. Screenshots 7–10 come from that session and look fine. |

So the grey frames appeared between 16:09:13 and 16:10:07. In that window, every frame's images had just been
reloaded at once, or deleted from under the gui.

### Two mechanisms in the code that each turn all 60 frames grey

1. **`AsyncImage` keeps its placeholder forever after a failed load.**
   * `FrameViewModel.thumbnailImage` and `previewImage` (`gui/star/FrameViewModel.swift:173`, `:232`) and
     `FrameEditImageView` all use `AsyncImage(url:content:placeholder:)`.
   * That initializer shows the placeholder until a load *succeeds*. A failed or cancelled load leaves it on
     screen until the URL changes again.
   * The placeholder is `Image(systemName: "rectangle.fill").resizable()` (`FrameViewModel.swift:649`): a flat
     light-grey rectangle filling the cell.
   * Every frame's URL changed at once at 16:09:13 and again at 16:09:25, while 18 keypoint ops started.
     Any load that failed or was cancelled stayed grey.
   * Nothing retries, and nothing logs the failure.
2. **The gui never hears about files a run deletes.**
   * `FrameGraphBuilder.invalidateStaleArtifacts` deletes outputs and aligned images, but each frame's
     `existingImages` set only ever grows (`FrameViewModel.frame` didSet, `saved(...)`).
   * So after 16:09:25 the gui still offered "final processed frame" and the Processed toggle for every frame.
   * Every frame then drew the dark-grey "image not found" panel (`Color(white: 0.15)`).

**Answered by the owner:** "a flat light grey rectangle filling each frame, nothing inside". That is mechanism 1, the
`AsyncImage` placeholder after failed loads. Task #837 fixes it.

Mechanism 2 (#838) is still a real bug, but it is not what the owner saw. Why every load failed at once is still
open:

* cancellation by the burst of `reloadID` changes is the leading suspect;
* running out of file descriptors was checked and is unlikely for that session (see #869).

#837's loader logs the reason for each failed load, so a recurrence will name it.

---

## 2. Proposed tickets

| ID | Title | Where | Size | Priority |
|---|---|---|---|---|
| A1 | gui frame images: no silent permanent placeholder, no main-thread file I/O, no stale image list | gui | M | high |
| A2 | Stop must stop: cancelled ops still reserve memory and run | core | S–M | high |
| A3 | A Stop is reported as "no usable star alignment was found" | core | S | medium |
| A4 | A Start right after a Stop can be dropped without a trace | core + gui | S–M | high |
| A5 | Concurrent `loadOutliers` returns early, so callers skip frames | core | S | medium |
| B1 | JPEG sequences write lossy intermediate caches; TIFF sequences don't | core | M | high |
| B2 | JPEG output is re-encoded at quality 95 whatever the source quality | core + both clients | S–M | medium |
| B3 | 8→16-bit promotion multiplies by 256, not 257 | core | S | low |
| B4 | Regression check: the same clip as TIFF-16, TIFF-8 and JPEG | tests | M | medium |
| C1 | Horizon line overlays decode full-size masks on every refresh | gui (+ daemon) | S–M | medium |
| C2 | Keypoints stored as YAML text: 1.4 MB a frame, slow to re-read | core | M | medium |
| C3 | Log noise: ~5 lines per frame on every open, a block per config change | core + gui | S | low |
| C4 | gui keeps every frame's outlier groups in memory | gui | M | low |
| D1 | gui painter swallows detection failures; the desktop shows them | gui | S | medium |
| D2 | gui "Processing complete" sheet clips the robot and the Cancel button | gui | S | medium |
| D3 | Catalogue-key parity check in CI, and the gaps it finds today | both + CI | M | medium |
| E1 | After a crash in a GPU merge, start the next session with GPU merge off | core + gui | S | low (optional) |

Suggested order: A1, A2, A4, B4 → B1 → B3, then the rest. A2 and A4 touch the same cancellation path, so they
go to one agent or run one after the other. Of the B tickets, only B3 changes output for an untouched 8-bit sequence;
B1 and B2 change it too, on purpose. Each of those bumps the artifact-input record so old caches are rebuilt.

---

### A1. gui frame images: no silent permanent placeholder, no main-thread file I/O, no stale image list

**Problem**

* Section 1: failed loads stay on a permanent placeholder, and deleted files are still offered.
* Each frame image `AsyncImage` calls `ImageAccessor.urlForImage` (`StarCore/…/ImageAccessor.swift:207`) from a
  SwiftUI view body on the main thread. That is two filesystem calls each time: `fileExists` and
  `attributesOfItem`. `hasImage(.userHorizon)` stats as well. On `/Volumes/sp`, a USB SSD that has stalled for
  minutes, this can freeze the UI.
* `refreshHorizonOverlay()` bumps `reloadID` (`FrameViewModel.swift:532`), so redrawing horizon lines re-reads the
  thumbnail JPEG from disk even though the lines are drawn in a separate `Canvas`.

**Change (Swift gui only)**

* Replace `AsyncImage` for frame pictures (filmstrip, grid, edit view, completion prompt) with a small loader.
  It decodes off the main actor, keeps a bounded LRU keyed by path and modification time (the shape of
  `star-desktop/…/data/ImageCache.kt`), and logs every failure.
* On a failed load: show a visible error state with the frame number, retry once, then queue a `PreviewOp`.
* Existence and modification time come from the loader's own cache, refreshed by the save and delete
  callbacks. View bodies do no file I/O.
* Add an image-deleted callback to `ImageAccessor` (beside `imageSavedClosure`) and use it to remove types from
  `existingImages`. That way the invalidation pass, `deleteMergeOutput` and the rest keep the "Show:" list and the
  Processed toggle true.
* Horizon-line refreshes no longer touch `reloadID`.

**Parity:** the desktop already has the cache and the failure logging. It needs only the deleted-image half if
`stard` does not already resend images on deletion; check `Session.swift`.

**Verify**

* A unit test: a failing loader shows the error state, then recovers once the file appears.
* A test that `invalidateStaleArtifacts` removes `.final` from `existingImages`.
* A main-thread file-access counter over the filmstrip body stays at zero.

### A2. Stop must stop: cancelled ops still reserve memory and run

**Problem**

* `AsyncOperation.start()` (`StarCore/…/AsyncOperation.swift:101–153`) never checks `isCancelled` after
  `acquireExecutionSlot()` or after `MemoryMonitor.shared.reserve(bytes:)`. Each can wait up to 60 s.
* `reserve` (`MemoryMonitor.swift:402`) does not react to task cancellation.
* So an op cancelled while it waits is still granted its reservation and runs its whole `asyncExecute()`.
* Today: reservations were granted 1.5 s after the Stop, and CPU, GPU and ledger stayed busy for seconds.

**Change**

* Check `isCancelled` after each wait. Release what was acquired and `finish()`.
* Make `reserve` cancellation-aware with `withTaskCancellationHandler`, removing the waiter.
* Have the heavy ops check `Task.isCancelled` between their main steps (keypoints, homography, merge).

**Verify:** a test cancels a queue of ops parked on the memory gate, and none of them reaches `asyncExecute`.

### A3. A Stop is reported as "no usable star alignment was found"

**Problem**

* `AlignmentValidationOp` (`StarCore/…/AlignmentValidationOp.swift:84`) runs after its cancelled dependencies,
  finds no homographies, logs `ERROR, canceling no homographies found`, and aborts the graph with "no usable star
  alignment was found between these frames, so the sequence cannot be processed".
* Today at 15:50:13 this came 33 ms after the Stop.
* The gui happens to drop the error because the generation changed. The daemon path and the log say the
  sequence cannot be processed.

**Change:** return early when the op or any dependency was cancelled, and log "cancelled".

**Verify:** a unit test cancels the homography ops and asserts that no error or abort closure fires.

### A4. A Start right after a Stop can be dropped without a trace

**Problem**

* At 16:09:53 a cancel arrived while a new `FrameGraphBuilder.build` was still constructing its graph.
  `FrameGraphBuilder.swift:1393` drops the build and returns without calling its completion closure.
* The gui never hears the run ended, so `isProcessingFrames` stays true and nothing runs.
* What issued that cancel is not known yet. Suspects:
  * `stopProcessing()` dispatches `cancelAllOperations()` in an unstructured `Task` (`ImageSequenceViewModel.swift:2773`),
    so it can land after a later `beginProcessing()`.
  * The startup sheet's Start sets `cleanMethod` and `allowEarthAlignment` right before `processAll()`.

**Change**

* Find the source.
* Make Stop's cancel synchronous with respect to the next Start, or tag cancels with the generation they are meant
  for.
* A dropped build must call its completion with a "cancelled" outcome.

**Verify:** a test runs Stop then Start back to back and asserts the second run enqueues and completes.

### A5. Concurrent `loadOutliers` returns early, so callers skip frames

**Problem**

* `FrameOutlierProcessor.loadOutliers` (`:242`) returns at once ("Not loading twice") while another load is in
  flight, and the caller then reads `getOutlierGroups() == nil`.
* `applyDecisionTreeToAllFrames` then `continue`s past that frame (`ImageSequenceViewModel.swift` ~3638), and
  fast-advance counts come out unknown.
* Every open starts two loads per frame. Today's logs have 60 "Not loading twice" warnings per open, one per
  frame, at each of today's three opens.

**Change:** keep one in-flight `Task` per frame that later callers await, and start one load per frame on open.

**Verify:** a test runs two concurrent loads, and both see the groups.

### B1. JPEG sequences write lossy intermediate caches; TIFF sequences don't

**Problem**

* Cache files reuse the source basename and extension (`ImageAccessor.dirAndNameForImage`, `:633`).
* `mat_wrapper_write_to` (`StarCpp/…/MatWrapper.cpp:646`) passes no parameters for `.jpg`, so OpenCV writes
  quality 95.
* Today's `star_temp` has JPEG files, 8-bit, in:
  * `aligned/` (the star-aligned merge),
  * `earth-aligned/`,
  * `aligned-subtracted/`, the subtraction image that outlier detection reloads (`AbstractBlobProcessor.setup`,
    `:225`, tries the file first),
  * `mergedHorizon/`, binary masks that pick up JPEG ringing at the edge,
  * `validated-outlier-images/`.
* A TIFF source gets lossless caches for all of these.

**Effects for JPEG sources**

* Re-processing outliers, or resuming, reads a compressed subtraction, so it finds different groups from the
  first run.
* Compression ringing around faint trails adds or reshapes blobs.
* Replaced pixels come from a compressed merge: a second generation of loss inside every repair.

**Change**

* Write every intermediate cache losslessly at the source's bit depth, whatever the source format. 8-bit PNG or
  TIFF; the subtraction image is mostly zeros and compresses to little.
* The final output stays in the user's format.
* Record the cache format in `ArtifactInputs` so old JPEG caches are rebuilt.
* Measure the disk cost first. The merges are the large part.

**Verify:** B4's comparison. Also, re-processing outliers twice on a JPEG sequence gives identical groups.

### B2. JPEG output is re-encoded at quality 95 whatever the source quality

**Problem**

* Output frames use the same writer, so a sequence imported at quality 80 comes out at 95.
* Today the output files were 685 KB against 214 KB for the inputs, with another generation of loss on pixels
  star never touched.

**Change:** default to the import quality recorded in `extraction.json`, or a fixed documented value. Add an output
format setting (keep the input format, PNG, or 16-bit TIFF) to both clients' settings, with catalogue keys in all
22 languages.

**Owner decision:** match the source quality, or add a setting?

### B3. 8→16-bit promotion multiplies by 256, not 257

**Problem**

* `mat_wrapper_ensure_16_bits` (`MatWrapper.cpp:799`) uses `convertTo(…, CV_16U, 256.0)`, so 8-bit white
  becomes 65280.
* Saturation tests and normalisations against 65535 (`UInt16.max`, `/0xFFFF` in brightness features,
  `SmallBlobRemover`'s default floor) therefore behave slightly differently for 8-bit sources.

**Change:** scale by 257 (exact inverse: `+128 >> 8`, or OpenCV's rounding), and audit the `ensure8Bits` direction.
This changes 8-bit outputs, so bump the detection algorithm version.

### B4. Regression check: the same clip as TIFF-16, TIFF-8 and JPEG

**Problem:** nothing compares how star treats the same footage in different formats, so B1 to B3 went unnoticed.

**Change**

* Extract one short clip (`test_a7sii_10` or a 10-frame cut of today's video) three ways: TIFF-16, TIFF-8 and
  JPEG at quality 95.
* Process each, then compare to the TIFF-16 result within tolerances: outlier-group counts, the removal oracle
  (trail-contrast ratio), and output PSNR.
* It runs in CI, or as a Gherkin scenario, with CPU merge.
* Land it first and record today's gaps as the baseline that B1 and B3 then shrink.

### C1. Horizon line overlays decode full-size masks on every refresh

**Problem**

* `loadHorizonThumbnailOverlays` (`FrameHorizonProcessor.swift:2441`) loads the frame's full-size masks
  (detected, reference or merged, consensus), separately for the thumbnail, frame and grid sizes.
* Refreshes come for all frames at once:
  * on painter save (60 at once today),
  * on each deleted mask,
  * on state changes.
* For a static sequence every frame draws the same reference.

**Change:** cache each mask's per-column rows (`[Int?]`, keyed by path and modification time) once, and scale for
each view from that. A static reference is computed once per sequence. Check whether `stard`'s overlay code needs
the same.

### C2. Keypoints stored as YAML text: 1.4 MB a frame, slow to re-read

**Problem**

* `OCVFeatureSet` writes keypoints and descriptors with `cv::FileStorage` YAML: 82 MB for this 60-frame sequence.
* The alignment validation logged "loaded keypoint positions for 60 frames in 1.3s". That is ~22 ms a frame, or
  ~2 minutes at 5,000 frames, and every resume re-parses every file.

**Change**

* A versioned binary format (header plus raw float32 arrays), with the YAML reader kept for old files.
* Measure load time and size before and after, min-of-K on real files.

### C3. Log noise: ~5 lines per frame on every open, a block per config change

**Problem.** Per frame, on every open:

* "file at …/horizon/… does not exist :(" twice (INFO),
* "no filename for type blobs at size original" (WARN): a caller asks for `.blobs` at `.original`, which has no
  file,
* "Not loading twice" once (see A5),
* a full `NSError` for a missing `outliers.bin` (INFO).

Every config change also logs a block of four lines: KeypointLimiter, MemoryMonitor, KeypointCache budget, and
"wrote config.json". That is dozens a minute while painting.

**Change:** fix the `.blobs` caller, demote the expected-missing cases to debug or one summary line, and log the
config-change block only when a value in it changes.

### C4. gui keeps every frame's outlier groups in memory

**Problem**

* `FrameViewModel.frame` didSet (`:150`) loads outliers for every frame as frames attach, and nothing releases
  them.
* Small here (2.3 MB on disk for 60 frames), but it grows with long selective sequences and slows every open.

**Change**

* Load on demand: the current frame plus a window.
* Read filmstrip badges from a light count.
* Release groups for frames far from the current one, if nothing has unsaved edits.

### D1. gui painter swallows detection failures; the desktop shows them

**Problem:** when band detection or a refinement stroke fails, the gui only logs it (`HorizonPainterView.swift:350`, `:508`).
The desktop shows `ui.horizon_detection_failed_adjust_the_band_and_try_again` and
`ui.refinement_failed_try_another_stroke` (`HorizonPainterView.kt:195`, `:220`, `:226`).

**Change:** show the same messages in the gui's painter toolbar. The keys already exist in all 22 catalogues.

### D2. gui "Processing complete" sheet clips the robot and the Cancel button

**Problem**

* Screenshot 10: the sheet is narrower than its content.
* The robot is cut in half on the left, the right "after" picture is cut, and the Cancel button is missing.
* The content is the art, plus two 240 pt pictures and the arrow, plus padding
  (`PostProcessingRenderPromptView.swift:23–70`). `.frame(maxWidth: .infinity)` on the picture row gives the sheet
  no definite ideal width.
* The desktop's `PostProcessingRenderPrompt` shows all three buttons.

**Change:** a fixed ideal width with `fixedSize`, and a `GUIViewSnapshot` test that asserts the Cancel button is
inside the sheet.

### D3. Catalogue-key parity check in CI, and the gaps it finds today

**Problem**

* 591 commits have touched the two clients since the parity plan (347 to `star-desktop`, 244 to `gui`).
* A diff of the catalogue keys each client uses finds keys one client uses and the other doesn't:
  * Desktop only: `ui.sequence_processed_with_other_version`, the painter failures (D1), and ~45 engine and daemon
    keys, which are legitimate.
  * gui only: `ui.render_video_no_frames`, `ui.processing_waiting_for_frames`, `ui.horizon_refinement_preparing`,
    `ui.there_is_no_new_release_available`, `ui.save_image`, and the developer blob-processing view.
* The two multi-frame dialogs use different key families: `ui.area.*` and `ui.overlap.*` against
  `multichoice.*` and `multiselect.*`. That breaks "same catalogue keys".

**Change**

* Add the key-usage diff as a Layer-0 static check (parity plan §6.2), with an allowlist for keys that are
  genuinely client-specific.
* Resolve what it flags today: port, share the key, or allowlist with a reason.

### E1 (optional). After a crash in a GPU merge, start the next session with GPU merge off

**Problem**

* This Mac's GPU merge locks up the window server more than half the time (CLAUDE.md).
* Today's gui session ran with it on: "GPU acceleration for the alignment/merge step is on (AMD Radeon Pro Vega
  64)".
* An end user with the same card would have the same experience, with nothing pointing at the cause.

**Change:** when the previous run's marker shows it died during a GPU merge, turn GPU merge off for the next session
and say so. The setting stays the user's.

---

## 3. Seen, not proposed

* The welcome screen's background shows colour banding (screenshot 1, lower half). Cosmetic, probably the intro
  video's encode.
* `PixelatedImage.binaryOtsuImage`'s 32-bit branch would allocate a 2³¹-entry histogram (16 GB). It can't be
  reached today, since only 8- and 16-bit images get there, but it is a trap for whoever adds float images.
* Re-importing into a `star_temp` that holds a finished run reopens it "complete". Painting a static reference
  afterwards correctly invalidates all of it. The warning is posted only once the run starts deleting; a word
  before the painter saves would be kinder. Left out because it is by design.
