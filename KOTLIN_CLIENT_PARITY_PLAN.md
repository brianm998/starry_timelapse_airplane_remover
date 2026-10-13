# Kotlin Client Parity Plan

**Status:** approved for implementation, 2026-10-13. Every item below was approved by the project owner.
**Reads with:** `KOTLIN_CLIENT_SPEC.md` (the original parity spec) and `CROSS_PLATFORM_DAEMON_DESIGN.md` (the daemon contract).
**Audience:** the agent implementing these changes.

This plan comes from a seven-way audit of the macOS SwiftUI client (`gui/star/`, the reference) against the Kotlin/Compose
desktop client (`star-desktop/`). It lists every place where the Kotlin client is still behind, wrong, or missing behaviour,
with a concrete implementation path for each. Several of the worst problems are not in the Kotlin code at all but in the
daemon (`stard`) handlers the Kotlin client relies on; those daemon fixes are part of this plan because they are the only
way to make the Kotlin client behave like macOS.

Line references were correct on `develop` at commit `d6ff8ade` (2026-10-13). They will drift as you work; re-find by
symbol name when a line no longer matches.

---

## 0. How to work on this

### 0.1 Path shorthand used throughout

| Shorthand | Path |
|---|---|
| `K:` | `star-desktop/src/main/kotlin/com/star/desktop/` |
| `D:` | `daemon/Sources/stard/` |
| `G:` | `gui/star/` (macOS reference) |
| `ISVM` | `gui/star/ImageSequenceViewModel.swift` |
| `SC:` | `StarCore/Sources/StarCore/` |
| proto | `daemon/proto/star.proto` (authoritative) + `star-desktop/proto/star.proto` (mirror) |

### 0.2 Architecture rules you must not break

- **Cardinal rule (KOTLIN_CLIENT_SPEC.md §0):** the Kotlin client contains ZERO StarCore-format serialization and ZERO
  pixel processing. If a fix seems to need Kotlin to parse `config.json`, write a `.bin`, compute a StarCore path, or
  touch pixels beyond display compositing — add or extend a `stard` RPC instead.
- **Use public StarCore APIs from the daemon.** Every daemon change below names the StarCore call macOS uses. If a piece of
  logic lives only in the gui target (e.g. `ProcessingSteps`, `SequenceProgressSurvey`, `affectedHorizonRefinementFrames`),
  **move it into StarCore** and have both the gui and the daemon call it, rather than duplicating it in the daemon.
- **Proto changes are additive.** New fields get new numbers; never renumber. Use proto3 `optional` when a zero value must
  not clobber a StarCore default.
- The protocol rides private dup'd file descriptors; the daemon logs to stderr. Never `print()` in the daemon.

### 0.3 Proto change workflow (every [D] item that touches the proto)

1. Edit `daemon/proto/star.proto`.
2. Regenerate Swift: `daemon/regen-proto.sh` (**never** a bare `protoc` — the script strips Swift-6.2-only `nonisolated`
   modifiers that break the macos-14 CI runner).
3. Mirror to the client: `cd star-desktop && ./gradlew syncProto` (then `./gradlew checkProtoSync` must pass).
4. Kotlin protos regenerate on the next gradle build.

### 0.4 Building in a git worktree

- **Daemon:** `cd daemon && swift build -c release`. In a fresh worktree this can fail with
  `'opencv2/core.hpp' file not found`. Fix by symlinking the gitignored prebuilts from the main checkout
  (`/Users/brian/git/nighttime_timelapse_airplane_remover`):
  ```
  ln -sfn <main>/opencv/include opencv/include
  ln -sfn <main>/opencv/lib opencv/lib
  ln -sfn <main>/opencv/opencv2.framework opencv/opencv2.framework
  ln -sfn <main>/StarDecisionTrees/include StarDecisionTrees/include
  ln -sfn <main>/StarDecisionTrees/lib StarDecisionTrees/lib
  ```
  First release build ≈5 min, ≈80 s after. The daemon always runs in **release** (debug is 5–10× slower).
- **Kotlin client:** `cd star-desktop && ./gradlew build` / `./gradlew test` / `./gradlew run`. `run` depends on
  `buildStardRelease`, which is Gradle up-to-date-aware.
- **Daemon tests:** `cd daemon && swift test` (target `StarDaemonTests`).
- **Integration tests:** `InteropIntegrationTest` (`star-desktop/src/test/kotlin/com/star/desktop/engine/`) spawns a real
  stard and self-skips without `-Dstar.it.*`. Run with
  `./gradlew test -Dstar.it.seq=<abs path to small_test_images> -Dstar.stard.path=../daemon/.build/release/stard`
  (add `-Dstar.it.process=true` for the processing tests). `small_test_images` frame 0 has **no** outliers; frames 1/2 do.
- **macOS gui** (only if you move code from gui into StarCore): `xcodebuild -scheme star` from `gui/` — never `-target Star`.
  The gui module name is `Star`.
- Desktop self-test: `K:tools/EngineSelfTest.kt` — extend it when you add an end-to-end path worth guarding in CI.

### 0.5 i18n

All four clients share one catalogue set: `StarCore/Sources/StarCore/Resources/Localizations/*.json` (22 languages +
`languages.json`). Kotlin reads it via `K:i18n/Strings.kt` (`localized(key, args)`). Rules:
- Every new user-visible string gets a key in **all 22** catalogues (English text is an acceptable placeholder in the
  non-English files only if a translation is impractical — but prefer real translations).
- Prefer reusing an existing `ui.*` key the macOS gui already uses (many exist; grep `en.json` before inventing one).

### 0.6 Commit and verify discipline

- One logical item (or a tight group) per commit; message names the plan item ID (e.g. `A4: …`).
- After each daemon change: `swift build -c release` + `swift test`. After each Kotlin change: `./gradlew build test`.
- Where an item says **Verify**, do it — most can be checked with the integration test harness against
  `small_test_images`; add a gated test when practical.
- Do not change StarCore processing behaviour. If you find a StarCore bug, note it and stop for that item.

### 0.7 Implementation order

Dependencies drive the order. Do the phases in sequence; items within a phase are mostly independent.

1. **Phase 1 — daemon plumbing that many items depend on:** A6, A7, A5, A8, A4, A18, A3, A17, A16.
2. **Phase 2 — persistence and rendering:** A1, A2, A11, A14, A15.
3. **Phase 3 — Kotlin correctness:** A9, A10, A12, A13, A19, G3, G7 (the bug parts), E7, F5.
4. **Phase 4 — horizon:** B2, B3, B4, B9, B5, B6, B7, B1, B8.
5. **Phase 5 — frame edit:** D2 then D1, D4, D5, D7, D6, D3, D10, D8, D9.
6. **Phase 6 — panels & processing UI:** E1, E2, E3, E5, E6, E8, E9, E10, E4, F1, F2, F3, F4, F6, C1, C2.
7. **Phase 7 — settings/render/info:** G1, G2, G4, G5, G6, G7 (remaining), G8.
8. **Phase 8 — app shell:** H1, H2, H3, H4, H5, H6, H7, H8, H10, H11, H9.

---

## Phase 1 / Section A — Data loss and correctness

### A1. Outlier decisions are never persisted [D+K] — functional bug, data loss

**macOS:** leaving a user-edited frame enqueues it on `FrameSaveQueue` (`G:FrameEditView.swift:83-104`). After 10 s
`SC:FrameSaveQueue.swift:28-105` runs `loadOutliers()` → `frame.finish()` (writes `OutlierGroupPaintData.json` + the
final output frame) → `changesHandled()`. Frame saving states (purgatory / pending / saving) are reported back.

**Kotlin today:** `K:ui/sequence/FrameViewModel.kt:152-161` sends `Outlier.SetDecisions(rerender=false)` and swallows
errors. Nothing reacts to leaving a frame.

**Daemon today:** `D:handlers/OutlierHandlers.swift:273-327` (`setDecisions`) only mutates in-memory groups and
`markAsChanged()`; it never calls `writeOutliersRemoveReasons()` or `finish()`. `Session.Close`
(`D:handlers/SessionHandlers.swift:115-123`) saves nothing. Edits survive only if the user later runs Render All.

**Implement:**
1. Daemon: give each `Session` its own `FrameSaveQueue` instance (StarCore's public type; check its init and how macOS
   wires its callbacks). Wire its saving-state callback into the existing `frame_saving_state` progress event.
2. After every edit RPC call `saveQueue.readyToSave(frame:)`: `Outlier.SetDecisions`, `ApplyAreaTool`,
   `ApplyDecisionTree`, `ApplyDecisionTreeAllFrames` (each changed frame), `SetDecisionsInArea`,
   `SetDecisionsOverlapping`, `Frame.SetCleanMethod`.
3. Also call `writeOutliersRemoveReasons()` synchronously in `setDecisions` (as `setDecisionsInArea` already does) so a
   crash before the 10 s timer still keeps the decisions.
4. On `Session.Close` and `Daemon.Shutdown`: `saveNow` every frame still queued, and await it before responding.
5. Kotlin: `ProcessingRepository.savingState` is already collected — expose a `pendingSaves: StateFlow<Int>` (count of
   frames in purgatory/pending/saving; check the `FrameSavingState` int values in the proto). H1 and E2 consume it.
6. Kotlin: when a frame finishes saving, invalidate its cached preview (see A11).

**Verify:** gated integration test — open `small_test_images`, process selective, set a decision on frame 1, close the
session, open the config again in a new daemon, `Outlier.List` frame 1 shows the decision.

### A2. "Render this frame", `r`, and `rerender` render the unedited original [D+K] — functional bug

**macOS:** `RenderCurrentFrameButton` → `viewModel.render(frame:)` → `FrameSaveQueue.saveNow` → `loadOutliers()` +
`finish()` (`ISVM:3217-3232`). "Render All Frames" is just `processAll()` (`G:RenderAllFramesButton.swift:10`).

**Daemon today:** `Outlier.RenderFrame` (`D:handlers/OutlierHandlers.swift:329-362`), the private `renderPreview`
(`:24-38`) and the `rerender` branch in `setDecisions` (`:301-320`) all load the **source image** and write it to
`previews/frame_N_rendered.png`. `Export.RenderSequence` (`D:handlers/ExportHandlers.swift:29-46`) calls `finish()` on
every frame **without** `loadOutliers()` first (on a resumed session the outliers are purged to disk, so frames are
written with nothing removed), re-renders already-complete frames, and never emits `IoProgress` — Kotlin's bar
(`K:ui/sequence/SequenceViewModel.kt:386-389`) stays at 0.

**Implement:**
1. Daemon `renderFrame` and `renderPreview`: `ensureOutliersLoaded(frame)` → `try await frame.finish()` →
   `frame.changesHandled()` (or route through the session save queue's `saveNow` from A1). Return the `.final` preview
   path from `imageAccessor` (same lookup `Frame.GetPreview` uses for `VIEW_PROCESSED` after A3), not a copy of the source.
2. `RenderSequence`: load outliers per frame before `finish()`; skip frames that are complete and not user-modified;
   emit `IoProgress(done,total)` after each frame.
3. Kotlin `renderCurrentFrame()` (`SequenceViewModel.kt:354-372`): after success, invalidate the frame's cached images
   (A11) and reload the preview in `VIEW_PROCESSED`.

**Verify:** edit a decision on frame 1, `r`, the returned preview differs from the original preview.

### A3. "Processed" view shows the subtraction debug image [D+K] — functional bug

**Daemon today:** `D:Mapping.swift:10-18` maps `VIEW_PROCESSED → .autoProcessed`. Selective frames never write
`autoProcessed`, so Kotlin's fallback (`K:ui/sequence/SequenceViewModel.kt:503-509, 528-533`, `PREVIEW_FALLBACK`)
lands on `VIEW_SUBTRACTION`. Scrub mode, the grid and "Preview first" therefore play subtraction frames; auto+outlier
frames show output that ignores the user's keeps.

**macOS:** the "final processed" view is `FrameViewMode.final` (`SC:FrameViewMode.swift:33`), which
`ImageAccessor.linkFinal` points at the processed type matching the frame's clean method
(`SC:FrameAirplaneRemover.swift:1640-1700`).

**Implement:** `Mapping.frameViewMode`: `.viewProcessed → .final`. Kotlin: reorder the fallback to
`PROCESSED, ORIGINAL, SUBTRACTION, VALIDATION` so a missing final shows the original, never a debug image.
Confirm `Frame.GetPreview`'s lazy `makeMissingImage` path handles `.final` (returns nil until written, which is fine).

### A4. Processing a single frame at index 0 runs/wipes the whole sequence [D+K] — functional bug, data loss

**Daemon today:** `D:handlers/ProcessingHandlers.swift:15-16` — `endIdx = req.endIndex > 0 ? … : nil`, so `end=0`
means "to the end". Kotlin's `processCurrent()`/`reprocessCurrent()` send `start=end=current`
(`K:ui/sequence/SequenceViewModel.kt:274-278`). At frame 0 with `force`, `Session.forceReprocess(0, nil)`
(`D:Session.swift:184-191`) resets **every** frame with `.everything`, deleting all output.

**Implement:**
1. Daemon: `endIdx = req.endIndex >= 0 ? Int(req.endIndex) : nil` (Kotlin already sends `-1` for "to the end"; check
   every other caller, including `EngineSelfTest`, `SmokeHarness`, and tests, sends `-1` not `0`).
2. Kotlin: `processCurrent()` → `processing.reprocessFrames(listOf(idx), REPROCESS_NONE)`;
   `reprocessCurrent()` → `reprocessFrames(listOf(idx), REPROCESS_EVERYTHING)` (macOS `ReProcessCurrentFrameButton`,
   `ISVM:3190`). Both via `startProcessingRun` so the modal re-arms.
3. Kotlin: `processRemaining()` → `processing.start(sessionId, currentIndex, -1)` (macOS
   `ProcessRemainingFramesButton` → `processFrames(from: currentIndex)`); relabel with
   `ui.process_frames_from_here_to_the_end`.

**Verify:** daemon unit/integration test that `Start(0,0)` processes only frame 0.

### A5. Stop doesn't stop processing [D+K] — functional bug

**macOS:** `stopProcessing()` → `frameGraphBuilder.cancelAllOperations()` (`ISVM:2582-2585`); a run counter makes the
old run's late completion a no-op (`ISVM:2701-2716`).

**Daemon today:** `Session.cancelProcessing()` (`D:Session.swift:150-153`) cancels only the wrapping `Task`, which is
parked in `AsyncSemaphore.wait()` (ignores cancellation). Queued graph ops keep running and still emit `"done"`.
`processingTask = nil` lets the next `Start` build a second graph alongside. The orphan's `clearProcessingTask()` can
clear the *new* run's task.

**Kotlin today:** `ProcessingRepository.cancel` (`K:data/ProcessingRepository.kt:82-85`) flips processing false at once;
`AppViewModel.awaitingProcessingPrompt` (`K:ui/app/AppViewModel.kt:233-242`) stays armed, so the stale `"done"` pops the
post-render prompt for a run the user stopped.

**Implement:**
1. Daemon: add a run generation counter on `Session`. `startProcessing` captures it; the completion only emits/clears if
   the generation still matches.
2. `cancelProcessing`: `await frameGraphBuilder.cancelAllOperationsAndWait()` (exists in StarCore; macOS uses it in
   `ISVM:1772-1784`), bump the generation, signal/abandon the semaphore, emit `SequenceStateEvent{state:"cancelled"}`.
   Make `Processing.Cancel` respond only after the wait.
3. Apply the same cancel-and-wait in `reprocessWithReferenceHorizon`, `forceReprocess`, `reprocessFrames` (they currently
   do the same broken `processingTask?.cancel()`).
4. Kotlin: `ProcessingRepository.fold` treats `"cancelled"` as not processing; `AppViewModel` clears
   `awaitingProcessingPrompt` and `autoRenderAfterProcessing` on cancel.

### A6. The progress stream gets killed or raced [D+K] — functional bug

**Kotlin today:** `K:ui/dialogs/RenderVideoDialog.kt:103` calls `processing.stop()` and nobody re-subscribes — after any
Render Video, frame states freeze and the next run's `"done"` never arrives (`isProcessing` stuck true, modal stuck,
buttons disabled). `SequenceViewModel.kt:383` and `:494` and `K:ui/sequence/edit/HorizonPainterView.kt:291` do the same
stop/re-subscribe dance.

**Daemon today:** one `progressContinuation` slot per session (`D:Session.swift:204`), set by
`ProcessingHandlers.swift:39`, `ExportHandlers.swift:22`, `HorizonHandlers.swift:234`, and set to `nil` by the same
handlers on stream end (`ProcessingHandlers.swift:53`, `ExportHandlers.swift:72`, `HorizonHandlers.swift:248`). An old
stream ending can wipe a newer stream's continuation. `Export.Video` uses its own stream and doesn't need the slot.

**Implement:**
1. Daemon: replace the single slot with a set of subscribers keyed by a token (`[UUID: Continuation]`); `emit` yields to
   all; each handler removes only its own token on termination.
2. `Export.RenderSequence` and `Horizon.Reprocess`/`RunRefinement` (B1) report progress by emitting on the shared
   subscriber set and return their own completion via a unary response or a terminal event on their own stream — they
   must not take over the long-lived `StreamProgress` subscription.
3. Kotlin: delete every `processing.stop()` except on session close. Keep exactly one long-lived
   `Processing.StreamProgress` subscription per session.

### A7. Frame states not seeded on open [D] — functional bug

StarCore reports each frame's initial state at construction (`SC:FrameAirplaneRemover.swift:441-452`), inside
`buildFrameGraph` (`D:Session.swift:64-66, 216`), before any stream exists — those events are dropped.
`exisingFrameStateChangeCallback` has no caller, so `frame_existing` is never sent. Kotlin's
`ProcessingRepository._frameStates` (`K:data/ProcessingRepository.kt:32,110`) starts empty, so LeftPanel shows
"0 / N complete", grid/filmstrip badges are blank and the modal's "X of N" (`K:ui/dialogs/ProcessingModal.kt:41-44`) never
reaches N on a resumed session.

**Implement:** in `ProcessingHandlers.streamProgress`, after registering the subscriber (A6), yield one
`FrameStateEvent` per frame with `await frame.processingState()`, then stream live. No Kotlin change needed (the fold
already handles it). **Verify:** resume a processed `small_test_images` config → Kotlin shows 3/3 complete immediately.

### A8. Processing errors and failed actions are never shown [D+K] — functional bug

**macOS:** `.error(msg)` → `report(error:)` alert and the render prompt is skipped (`ISVM:2716-2726`); individual actions
report failures (`ui.render_failed`, `ui.decision_tree_render_failed`).

**Daemon today:** `D:Session.swift:132-145` logs the error list and writes `processing_errors.log`, but always emits `"done"`.

**Implement:**
1. Proto: add `string message = 2;` to `SequenceStateEvent` (check the next free number).
2. Daemon: when `errorList` is non-empty, emit `state="error"` with the joined errors instead of `"done"`.
3. Kotlin: `ProcessingRepository.fold` sets processing false and publishes an error; `AppViewModel` shows the
   `ErrorOverlay` and does **not** call `handleProcessingDone` (no render prompt).
4. Kotlin: pass an `onError: (String) -> Unit` from `AppViewModel` into `SequenceViewModel`/`FrameViewModel` and route
   every `runCatching` that currently swallows a user-action failure to it: `SequenceViewModel.kt:289, 368, 394`,
   `FrameViewModel.kt:87, 130, 138, 159`. Use the macOS keys.
5. Kotlin: a failed `SetDecisions` reverts the optimistic tint (`FrameViewModel.kt:154-160`) — reload the frame's
   decisions on failure.
6. Error overlay: add the "Error" heading and label the button "Close" like macOS (`K:ui/app/StarApp.kt:231-247`).

### A9. Clear Undecided does nothing [K] — functional bug

`K:ui/sequence/FrameViewModel.kt:149-150` maps undecided groups to `RR_UNDECIDED` (no-op). macOS sets them to keep:
`G:ClearUndecidedButton.swift` → `setUndecidedFrameOutliers(to: false)` (`SC:FrameOutlierProcessor.swift:728-740`).
**Fix:** use `RemoveReason.RR_USER_KEEP`.

### A10. Decision-tree actions overwrite manual decisions [K] — functional bug

**macOS:** "Decision Tree All" (`d`) on the **current frame**, all outliers, `overwrite: !classifyOnlyUnclassified`
(default `true` → overwrite false), `minimumSize: 20`, then renders (`G:ApplyAllDecisionTreeButton.swift:18-25`,
`ISVM:1840-1843`). "DT Auto Only" uses `autoOnly` + `includingTrash: shouldShowTrash` (`G:ApplyDecisionTreeButton.swift:12`).
RightPanel has an "Only Unclassified" toggle (`G:RightPanel.swift:218-221`).

**Kotlin today:** `RightPanel.kt:100` + `FrameViewModel.kt:136-141` always `overwrite=true`, `minimumSize=0`, no render;
"Apply Tree (All Frames)" (`SequenceViewModel.kt:288-291`) whole-sequence `overwrite=true`. No `d` key, no auto-only, no
toggle.

**Implement:** `SequenceViewModel` gets `classifyOnlyUnclassified` (default true, persisted in `LocalPreferences` under the
macOS key if one exists) and `minimumClassificationSize = 20`. All apply-tree calls pass
`overwrite = !classifyOnlyUnclassified`, `minimumSize = 20`, `includingTrash = showTrash` (D6). Add a "DT Auto Only"
button (`autoOnly = true`), the toggle, and `Key.D` in `K:ui/app/KeyHandling.kt`. Keep the all-frames action but label it
clearly and give it the same flags. After applying, re-render the frame (A2) and invalidate affected frames (A11).
Localize the button labels.

### A11. Stale frames, stale images, bulk ops outside edit mode, unknown outlier counts [D+K] — functional bug

Problems:
- `FrameViewModel.load()` is one-shot (`K:ui/sequence/FrameViewModel.kt:61-63`; `FrameEditView.kt:54`); `frameVMs`
  (`SequenceViewModel.kt:195-199`) never cleared. A frame viewed before processing stays empty forever; apply-tree-all and
  multi-frame sheets reload only the current frame (`SequenceViewModel.kt:290, 340, 349`). The `FrameInfo` in
  `SetDecisions`/multi-frame responses is discarded.
- Previews: retried only when nothing was available (`SequenceViewModel.kt:215-222`); a frame showing an original as a
  fallback is never upgraded. `K:data/ImageCache.kt:28-33` is keyed by path and never invalidated though the daemon
  rewrites files in place.
- Keep All / Remove All / Clear Undecided from menu or keys operate on `_groups`, empty unless `FrameEditView` loaded
  them → silent no-op in scrub/grid (`StarMenuBar.kt:104-112`, `FrameViewModel.kt:147-150`).
- `Frame.Get` (`D:handlers/FrameHandlers.swift:18`) doesn't `ensureOutliersLoaded`, so unloaded frames report 0/0/0; fast
  skip (`SequenceViewModel.kt:419-435`) treats that as empty and jumps to the sequence end. macOS refuses to skip a frame
  whose outliers aren't loaded (`ISVM:3281-3301`).

**macOS:** the image-saved callback bumps `reloadID` (`G:FrameViewModel.swift:89-98`); outliers reload when counts change
(`G:FrameEditImageView.swift:219-236`).

**Implement:**
1. Proto + daemon: new `ProgressEvent` arm `ImageSaved { int32 frame_index; FrameViewMode view_mode; }` emitted from
   StarCore's image-written callback (find the hook macOS uses for `reloadID`). Also emit after A2 renders.
2. Proto + daemon: `FrameInfo` gets `bool outliers_loaded` (true when `getOutlierGroups() != nil`). Do **not** eagerly load
   in `Frame.Get` (grid scrolling would load every frame).
3. Kotlin `ImageCache`: `invalidate(path)` / `invalidateFrame(index)`; on `ImageSaved` invalidate and, if it's a visible
   frame, reload.
4. Kotlin `FrameViewModel`: `invalidate()` (sets `loaded=false`) and `suspend fun ensureLoaded()`. Invalidate on:
   `outliers_loaded` events, frame-state changes for that frame, frames listed in multi-frame / apply-all responses,
   clean-method change (G3). Force-reload the current frame if it's invalidated. Consume `FrameInfo` from responses.
5. Bulk ops (`keepAll/removeAll/clearUndecided`) `ensureLoaded()` before acting. Better: add daemon
   `Outlier.SetAll { session_id, frame_index, should_remove, undecided_only, including_trash }` calling
   `userSelectAllOutliers` / `userSelectUndecidedOutliers` directly, and use it.
6. Fast skip: `skip = info.outliersLoaded && count == 0` (don't skip unknown).

### A12. Hit-test label image leaks memory [K] — functional bug

`K:data/OutlierRepository.kt:83-106` holds a full-resolution `IntArray(w*h)` per visited frame (~170 MB at 42 MP),
kept forever in `frameVMs`; `build.gradle.kts` sets no `-Xmx`. **Fix:** store a `ShortArray` (ids are UInt16); retain label
data only for current ±2 frames (drop on leave); evict label-image bitmaps from `ImageCache`. Consider setting a sensible
`-Xmx` default in the Compose `jvmArgs`.

### A13. Startup answers are lost or overwritten [K] — functional bug

**macOS:** each answer writes through to the config immediately (`ISVM:690-696, 939-945`; set at
`G:StartupView.swift:76, 94, 155, 177`); Close keeps them (`:481-484`); Advanced on the first screen leaves StarCore's
default `horizonDetectionEnabled = true` (`SC:Config.swift:793`). Resume reads from the loaded config (`StartupView.swift:427-430`).

**Kotlin today:** private `startupHasHorizon`/`startupCameraMoving` vars. `resumeStartupHorizonIfUnfinished`
(`K:ui/app/AppViewModel.kt:399-410`) never seeds them → `applyStartupChoices` (`:477-485`) writes `false/false` into the
resumed config, so a moving sequence runs static with no horizon. `dismissStartup()` (`:469`) applies nothing;
`startupOpenAdvanced` from HORIZON (`:451-457`) forces false. `defaultInitialConfig` (`K:data/SessionRepository.kt:69-73`)
leaves `horizon_detection_enabled` false. Back on REMOVAL after resume goes to MOVING, not SELECT_MOVING_HORIZONS.

**Implement:** delete the private vars; `startupAnswerHorizon`/`startupAnswerMoving` call `sessions.updateConfig`
immediately and read back from the live config. Only clean method + earth alignment are applied at Start. Set
`horizonDetectionEnabled = true` in `defaultInitialConfig`. Fix the Back target after resume. Extend
`StartupHorizonTest` to cover resume→Start keeping horizon/moving true.

### A14. Recent files store the wrong path [D+K] — functional bug, breaks the macOS client too

**macOS:** stores `<tempOutputPath>/config.json` (`G:ViewModel.swift:417, 493-497`); opens every recent as a config
(`G:InitialView.swift:333-338`); prunes missing entries on load (`G:UserPreferences.swift:184-197`).

**Kotlin today:** `K:ui/app/AppViewModel.kt:640-643` stores the folder/video path into the **shared**
`~/.star.userprefs.json`; reopening runs a fresh open (fresh UUID scratch, startup questions again, video re-decoded); the
macOS app later fails to open those entries as configs. `LocalPreferences.kt:76-78` trims the shared list to 20 (deletes
the Mac app's older entries); no pruning.

**Daemon today:** for a fresh open, config.json is written into the scratch session dir (`D:Session.swift:298`), not the
sequence temp dir macOS uses. The run-marker resume path (`D:SessionManager.swift:32`, `config.jsonPath(named:)`) points
at the macOS location, which the daemon never writes — so crash Restart (H3) and cross-client resume both break.

**Implement:**
1. Daemon: write config.json where macOS does (`config.jsonPath(named:)` under the sequence's temp output dir) — via
   `ConfigManager` once the `writeJson(named:)` path-mangling bug noted in the old daemon fix is handled — and report that
   path in `SessionInfo.config_json_path`. Keep the run marker pointing at the same file.
2. Kotlin: record `info.configJsonPath` for all open kinds; keep `inferOpenKind` for legacy entries; treat any `.json`
   as a config.
3. `LocalPreferences`: remove the 20 cap (or apply it only to Kotlin's own view, never on write); prune missing paths on
   load; **re-read the file immediately before every save** and merge (avoids clobbering concurrent macOS edits).
4. Recent rows: title config entries by parent folder name, not "config.json" (`K:ui/initial/InitialView.kt:180`).

**Verify:** open a sequence in Kotlin, quit, reopen from recents → resumes (no startup prompts); the recorded path opens in
the macOS app.

### A15. Video imports write output into hidden scratch [K] — functional bug

`AppViewModel.openVideo` (`K:ui/app/AppViewModel.kt:532-560`) sends no output path → daemon uses
`~/.star-scratch/<uuid>/output` (`D:Session.swift:351`). macOS: parent of the extracted frames folder, i.e. beside the video
(`ISVM:1919-1930`). **Fix:** pass `defaultInitialConfig().toBuilder().setOutputPath(File(path).parent)` to
`sessions.openVideo`. Also add the engine-down check `launchOpen` has.

### A16. Session lifecycle leaks [D+K] — functional bug

**Kotlin today:** opening while a session is open (`StarMenuBar.kt:31-39` always enabled) → `launchOpen` → `onOpened`
closes the old one client-side only (`AppViewModel.kt:654`), no `Session.Close`, no cancel. `closeSession`
(`:562-569`) doesn't cancel. App-scope coroutines added per open are never cancelled (`AppViewModel.kt:657`,
`SequenceViewModel.kt:209-226`).

**Daemon today:** `Session.Close` (`D:handlers/SessionHandlers.swift:115-123`) only removes the dictionary entry;
processing keeps running against the shared global frame-graph builder, which the next session repoints.

**Implement:** daemon `Close` = cancel-and-wait (A5) → save queue flush (A1) → `configManager.flush()` → finish all
progress subscribers → drop. Kotlin: each `SequenceViewModel` owns a child `CoroutineScope` cancelled on close; opening
over an open session does cancel → `Session.Close` → open; `closeSession` resets app-level state (warnings H2, prompt
flags, open dialogs, `awaitingProcessingPrompt`).

### A17. Detection Strength changes are ignored until reopen [D]

`D:handlers/SequenceHandlers.swift:32` stores `config.detectionType`, but the outlier stage reads the global
`constants` (`SC:FrameOutlierProcessor.swift:167,191`), set only at open (`D:Session.swift:302,375,418`). macOS sets it on
change (`G:ProcessingSettingsView.swift:1830-1837`, `G:RightPanel.swift:359`). **Fix:** after `configManager.update` in
`updateConfig`, `await constants.set(detectionType: config.detectionType)`.

### A18. Daemon reprocess types delete the wrong things [D]

`Session.resetFrames` (`D:Session.swift:169-181`) always sets `.unprocessed` and `deleteAllImages(type)`: `REPROCESS_NONE`
deletes outputs (macOS deletes nothing), `EVERYTHING` keeps aligned/subtraction (macOS also `deleteAllProcessedImages`),
`HORIZONS` deletes outputs (macOS only horizon images). **Fix:** port the per-type `switch` from macOS `processFrames`
(`ISVM:3075-3098`), ideally by moving it into StarCore so both call one function.

### A19. Menu "Process All" skips the render prompts [K]

`K:ui/app/StarMenuBar.kt:56` calls `svm?.processAll()` directly, bypassing `AppViewModel.requestProcessAll()`
(`AppViewModel.kt:196-205`). Route the menu item (and any other process-all entry point) through `requestProcessAll()`.

---

## Section B — Horizon painter

Kotlin files: `K:ui/sequence/edit/HorizonPainterView.kt` (`HPV.kt`), `K:ui/sequence/edit/HorizonPaintState.kt`
(`HPS.kt`), `K:data/HorizonRepository.kt`. macOS: `G:HorizonPainterView.swift` (`HPV`), `G:HorizonPaintState.swift` (`HPS`).

### B1. Replace Save & Reprocess with macOS's pending-refinement workflow [D+K]

**Today:** `HPV.kt:284-298` stops progress (see A6) and collects `Horizon.Reprocess` discarding events; that stream never
completes (`D:handlers/HorizonHandlers.swift:227-252` waits for a channel `Session.reprocessWithReferenceHorizon` never
closes). The handler ignores `edited_frame_indices`; `reprocessWithReferenceHorizon` (`D:Session.swift:157`) restarts the
whole graph, which skips completed frames (`SC:FrameGraphBuilder.swift:711-716`) — so nothing near the edit recomputes.

**macOS:** "Apply to nearby frames" toggle (`HPV:770`); on save computes affected frames and asks "Re-run now or later?"
(`G:ImageSequenceView.swift:132-144`, `ISVM:1168-1186`). Now: clear reference stats cache, discard stale merged horizons
and merge output, enqueue only horizon refinement + merge for affected frames (`ISVM:1392-1536`). Later: strip stale output
(`ISVM:1204-1248`), mark frames pending (orange, `ISVM:1120-1141`), fold pending work into the next Process
(`ISVM:1275-1315`, called at `:2709` and `:3061`), return claimed work if a run is stopped (`:1107`). Right panel has
"Re-run Horizon Refinement" (`G:RightPanel.swift:154-162`).

**Implement:**
1. Move `affectedHorizonRefinementFrames`, `deferHorizonRefinement`, `reprocessHorizonsForUpdatedReferences` and the
   pending-set bookkeeping out of `ISVM` into StarCore (a `HorizonRefinementPlanner` or similar), and make the macOS gui
   call the moved code (no behaviour change there).
2. Daemon `Session` holds the pending sets (affected, updated references, stripped). New RPCs:
   - `Horizon.ReferenceUpdated { session_id, frame_index, apply_to_nearby } → { affected_frame_count, render_count }`
   - `Horizon.DeferRefinement { session_id }` (Later)
   - `Horizon.RunRefinement { session_id }` (Now) — enqueues via the session's `frameGraphBuilder`, reports on the
     shared progress subscribers (A6), responds when queued.
   - `Processing.Start` applies pending sets first; Cancel returns claimed work.
   - Per-frame pending flag: add `bool refinement_pending` to `GetHorizonOverlayResponse` and to `FrameInfo`.
   - Remove `Horizon.Reprocess` once no client uses it (or keep it as an alias of RunRefinement).
3. Kotlin: toggle in `HorizonControlBar`; Now/Later dialog hosted at `SequenceScreen` level (not inside the painter, which
   closes); "Re-run Horizon Refinement" button in `RightPanel.kt`; orange colour for pending frames wherever overlays draw
   (grid, filmstrip, edit view — B7).

### B2. Painting sky below the loaded band snaps back [K]

**macOS:** `commitRefinementGesture` widens the band under the brush before moving the known-sky/known-ground limits
(`HPS:529-574`, especially `:540-542`, `:557-559`), then makes the band contain the tapered seeds (`HPV:480-492`), and
applies the most recent gesture's clamp last (`HPV:539-550`).
**Kotlin:** `HPS.kt:184-208` never touches `bandTop/bandBottom`; ground-ceiling retraction clamped to `bandBottom`
(`:203-204`); `localBand` (`:216-235`) lacks the seed/band pass; `applyRefinedHorizon` (`:286-292`) always applies the
ground ceiling last.
**Fix:** port `HPS:540-542, 557-559` and `HPV:485-492`; pass `erasing` into `applyRefinedHorizon` and order the two clamps
as `HPV:542-548`. Add a unit test: a frame whose stored horizon is off by more than the ±max(50, h/10) margin; painting sky
below the band sticks.

### B3. Save failures are silent; normal-mode save flips a global flag [K]

- `HPV.kt:289, 304` wrap `setReference` in `runCatching` then close/advance regardless; in startup this records progress
  for a frame with no reference. macOS shows `saveError` and stays open (`HPV:1097-1101`). **Fix:** keep the result; on
  failure set `errorText`, stay, don't advance. Add `isSaving` to disable Save (macOS `canSave`, `HPV:1017-1022`).
- `HPV.kt:289` sends `setStaticReference = true` on every save; the daemon flips `hasStaticReferenceHorizon`
  (`D:handlers/HorizonHandlers.swift:36-38`), so the next run skips per-frame detection. macOS sets it only when finishing
  the startup flow (`ISVM:411-424`). **Fix:** `setStaticReference = startup`.

### B4. Closing discards work; "Done" is misleading [K]

macOS auto-saves on close-by-toggle (H, right panel button, leaving edit mode) during refinement (`HPV:636-669`); only
Cancel/Esc discards. Kotlin's non-startup "Done" calls `toggleHorizonPaint()` (`HPV.kt:309, 452, 493`); H and mode switches
discard. **Fix:** relabel to Cancel; a `DisposableEffect`'s `onDispose` triggers a save when not startup, phase is
refinement and no explicit cancel happened — launched in the **view model's** scope (the composable scope dies on dispose).

### B5. No zoom/pan in the painter [K]

macOS hosts the painter in `ZoomableView` with zoom-compensated cursor and marching ants (`G:FrameEditView.swift:285-289`,
`HPV:130-134, 157`). `HPV.kt:96` creates a `FrameTransform` but never zooms or pans. **Fix:** reuse the D2 zoom/pan
handling (scroll/Ctrl+scroll, double-click toggle, middle/space-drag pan so it doesn't collide with painting); share the
transform with the edit view.

### B6. Painter shortcuts and key conflicts [K]

macOS: `[`/`]` brush size, `-` toggles sky/ground, `p` sky, `e` ground, `r` reset (`HPV:265-305`); Esc cancels, Return
saves under the button's conditions (`HPV:994-1005`); scrub disabled during startup painting (`G:StarCommands.swift:119`).
Kotlin: none; global R renders (`KeyHandling.kt:38`); menu E/S accelerators change mode (`StarMenuBar.kt:46-48`); S/G
during startup painting hides the painter with the startup flag still set.
**Fix:** `onPreviewKeyEvent` on the painter root with focus requested; `handleGlobalKey` returns early when
`horizonPaintMode`; disable the E/S/G menu items while painting (Compose menu accelerators fire before content key
events), at minimum S/G during startup. Update the startup tip to mention `[`/`]`.

### B7. Horizon overlay on the edit view and filmstrip [K]

macOS persisted pref `showHorizonOnMainView` draws the line on the edit view (zoom-compensated, `G:FrameEditView.swift:256-279`),
filmstrip (`G:FilmstripImageView.swift:116-133`) and grid (`G:GridView.swift:137-166`); colours: orange pending, white
initial, blue merged, green reference. Toggled from RightPanel (`G:RightPanel.swift:168`), the grid panel, and Preferences.
Refreshes after save (`HPV:1068-1086`) and on frame-state change (`ISVM:2391-2397`). GridRightPanel shows
"Horizon: Pending/Set" (`G:GridRightPanel.swift:185-187`).
Kotlin: grid only, in-memory `_showHorizonOnGrid` (`SequenceViewModel.kt:76-78`); grid overlays reload only on state change
(`GridView.kt:116-120`); no orange; no right-panel toggle or painter button.
**Fix:** persist `showHorizonOnMainView` in `LocalPreferences` (macOS key); draw in `FrameEditView.kt` through the frame
transform and in `Filmstrip.kt`; per-frame overlay version counter bumped by painter saves and refinement completion;
RightPanel toggle + "Paint Horizon" button; GridRightPanel Horizon row; orange from B1's pending flag.

### B8. "Max downward extension" control [D+K]

macOS: ±10 px stepper showing effective `↓Npx`, stored per sequence in `horizonReference/tuned_parameters.json`
(`HPV:899-964`). **Daemon:** `Horizon.GetTunedParameters` / `SetTunedParameters` wrapping
`frame.loadTunedHorizonParameters` / `saveTunedHorizonParameters`; Get also returns
`HorizonTunedParameters.effectiveMaxDownwardExtension(configured:searchRadius:)`. **Kotlin:** `MaxDownwardExtensionControl`
in the refinement bar.

### B9. Smaller painter fixes [K]

- Save the **solver** result, not the brush preview: keep `solvedHorizon` alongside `horizonY`; save from it; restore
  `horizonY` from it when refinement fails (macOS `lastHorizonY`, `HPS:265-276, 830`; Kotlin `HPS.kt:163-172`,
  `HPV.kt:159-160`).
- Remember Sky/Ground mode across frame advances and painter reopen: move the `isErasing=false` out of
  `transitionToRefinement` (`HPS.kt:308`); keep the mode in `SequenceViewModel` (macOS `HPS:626-639`, `ISVM:394`).
- Startup instructions "Don't show again" → `LocalPreferences` flag `showHorizonPainterInstructions` (macOS
  `G:FrameEditView.swift:582, 619-627`), re-enabled from Preferences (H4). Kotlin "Got it" is session-only (`HPV.kt:376-409`).
- Cosmetic: cursor label text ("Select area with horizon"/"Calculating"/"Select sky"/"Select ground", `HPV:159-201`);
  grey cursor while refining (`HPV:170`); Reset disabled when nothing painted (`HPV:721`); marching ants pause during drag
  (`HPV:83-85`); brush defaults radius 250, range 5–500, step 10 (`HPS:150-153, 301-307`; Kotlin scales with width,
  `HPS.kt:47-52`); refinement margin fixed 20 px (`HPV:412` vs `HPV.kt:146`).

---

## Section C — Alignment charts

Kotlin: `K:ui/windows/AlignmentWindowView.kt`, `K:data/AlignmentRepository.kt`. macOS: `G:AlignmentWindowView.swift`.
(macOS shows no aligned previews and has no actions in this window; `Alignment.Get` preview data is not needed.)

### C1. Alignment window parity [D+K]

1. **Live refresh:** today a one-shot `produceState` keyed on session id (`AlignmentWindowView.kt:45-48`). Collect
   `svm.frameStates`, debounce ~1 s, re-fetch `Alignment.GetSequence` (or per-frame on star/earth alignment complete).
2. **Earth charts** when `allowEarthAlignment` (macOS `:52-68`); data already in `AlignmentInfo.earth`,
   `has_earth_results`, `num_earth_keypoints`. Parameterise `DeviationChart`/`KeypointChart` with a selector.
3. **Suspect warps in red** (`:413-421, 627-669`): proto `bool suspect = 6` on `NeighborHomography`, set in
   `Mapping.protoHomographyResults` from `h.partitionWarps().suspect` (`SC:HomographyResultsCodable.swift:85`).
4. **Hover tooltips** (frame, offset, deviation green/red, alignment state; keypoint chart frame+count — `:435-456, 674-747,
   186-206`): `onPointerEvent(Move)`, nearest point, popup.
5. **X zoom/pan** (drag pan, wheel zoom, min span 20, `:263-299, 541-579`), **keep current frame in view** (`:531-539`),
   **"Height" slider** 5–100 default 50 for a fixed symmetric y range (`:370-390, 472`) — today y autoscales so one outlier
   flattens everything (`:72, 99`).
6. **Series toggles** (star/earth deviation, keypoints); legend lists only visible series (`:76-120`).
7. **Palette:** `palette[(abs(offset)-1) % 8]` (`:844-850`; Kotlin `:86-89` is off by one).
8. **Labels:** red "Current" on the current-frame line, axis titles ("Frame index", "Deviation", "Number of key points"),
   "Neighbor offset" legend title. Localize.

### C2. Shared chart composable in LeftPanel and the processing modal [K]

macOS embeds the deviation chart in LeftPanel (`G:LeftPanel.swift:108-112`) and the processing modal
(`G:ProcessingModalView.swift:300-330`, with `showAlignmentInProcessingWindow` pref and "Waiting for alignment data"
placeholder). Extract the chart into `ui/components/AlignmentChart.kt` fed from one live alignment `StateFlow` in
`SequenceViewModel` (the C1 refresh), and use it in all three places. Persist the pref.

---

## Section D — Frame edit and outliers

Kotlin: `K:ui/sequence/edit/FrameEditView.kt`, `FrameTransform.kt`, `ToolCursors.kt`, `K:ui/sequence/FrameViewModel.kt`,
`K:domain/ToolType.kt`, `K:ui/windows/OutlierWindowView.kt`, `K:ui/dialogs/MultiFrameSheets.kt`.

### D1. Remove / Keep / Information box-drag [K]

macOS: drag with Remove/Keep sets every group fully inside the box (`G:FrameEditView.swift:377-384` →
`userSelectAllOutliers(between:)`); drag with Information lists all groups in the box, largest first, in the outlier window
(`:431-460`). The shared help strings (`tool.help.remove/keep/information`) promise this and Kotlin shows them.
Kotlin `ToolType.kt:44-45` excludes these from `isAreaDrag`, so `FrameEditView.kt:121-127` pans.
**Fix (after D2 so panning keeps a gesture):** include them in `isAreaDrag`; on drag end Remove/Keep →
`Outlier.SetDecisionsInArea` (start=end=current, `overlapping=false`, `including_trash = showTrash`) then reload;
Information → filter groups whose bounds are fully inside, sort by size desc, `SequenceViewModel.showInfoFor(ids)` (D8).

### D2. Zoom and pan rework [K]

- Area tools make drag draw a box and scroll only zoom (`FrameEditView.kt:90-97`) — once zoomed there's no way to pan.
- `remember(current) { FrameTransform(...) }` (`:68`) resets zoom every frame; macOS keeps `currentZoomScale`.
- macOS has a zoom slider and editable max zoom (`G:RightPanel.swift:268-282, 509-549`) and can't zoom out past fit;
  Kotlin allows 0.1× fit (`FrameTransform.kt:65`).
**Fix:** move `FrameTransform` into `SequenceViewModel` (one per session, shared with the painter B5). Plain scroll pans;
Ctrl/Cmd+scroll zooms (around the cursor); middle-drag and space+drag pan in every tool; double-click toggles fit/100%.
`MIN_ZOOM = 1` (fit). Zoom slider + max-zoom field in `RightPanel.kt`.

### D3. "Show full resolution" + thumbnail size [D+K]

macOS toggle (`G:RightPanel.swift:284`) loads the original-size image (`G:FrameEditImageView.swift:16-67`); filmstrip uses
`.thumbnail`. Kotlin always draws the ~1617 px preview stretched under full-res overlay coordinates.
**Daemon:** `ImageDisplaySize size = N` on `GetFramePreviewRequest` (preview default, thumbnail, original) mapped to
`imageAccessor.nameForImage(..., atSize:)` + `makeMissingImage(... andSize:)`. **Kotlin:** toggle in `SequenceViewModel`;
when on and zoom > fit, load the original into a separate bitmap; filmstrip (E6) requests thumbnails. Mind memory (A12).

### D4. Draw outliers like macOS [K]

macOS: groups > 40 px show their actual pixels tinted (red remove, green keep, blue undecided, orange selected) with
hard-light blend (`G:OutlierGroupView.swift:229-233`); groups ≤ 40 px are two combined red/green masks, not clickable
(`G:FrameEditImageView.swift:187-213`, `G:FrameViewModel.swift:333-426`); box fill/border only on hover/selection
(`OutlierGroupView.swift:197-207`); arrow-length margin around the frame at fit (`G:FrameEditView.swift:30-42`); no outlier
overlay when the frame's clean method doesn't use outliers (`FrameEditImageView.swift:76, 173`).
Kotlin draws a filled bordered box + arrows for every group (`FrameEditView.kt:187-234`), clips edge arrows at fit
(`FrameTransform.kt:23-25`), draws on Automatic frames.
**Fix:** build an overlay `ImageBitmap` from the label map + decisions (id → colour), rebuilt when decisions change, at
preview resolution (full-res when D3 is on); boxes/guide lines only for hovered/selected; skip arrows and hit-testing for
≤ 40 px groups (draw them in the masks); fit to `(w + 2·w/70) × (h + 2·w/70)`; no overlay unless the frame's method uses
outliers. Approximate hard-light with alpha blending if Compose lacks it (documented existing limitation).

### D5. Hit-testing by bounding box; clickable arrows [K]

macOS: click/hover anywhere in a group's bbox hits it; overlaps resolve smallest-on-top (`G:FrameEditImageView.swift:205`,
`G:OutlierGroupView.swift:237-242`); edge arrows are clickable and toggle the group (`:346-362`). Kotlin uses the exact
label pixel (`FrameEditView.kt:137, 161`). **Fix:** exact pixel first, else smallest > 40 px group whose bounds contain the
point; add arrow hit areas.

### D6. Trash workflow [D+K]

macOS: "Show trash" toggle (`G:RightPanel.swift:163-165`), yellow trash mask with opacity (`G:FrameEditImageView.swift:177-185`,
`G:FrameViewModel.swift:428-481`); choosing Get from Trash enables it (`ISVM:266-272`); razor, Remove/Keep drags, Keep/Remove
All, Clear Undecided, multi-select and DT Auto Only all pass `includingTrash: shouldShowTrash`; bottom bar shows trash count.
Kotlin has none; `applyAreaTool` never sets `includingTrash` (`FrameViewModel.kt:130`), nor multi-select
(`SequenceViewModel.kt:347`).
**Daemon:** `Frame.GetOutlierTrashImage { session_id, frame_index } → ImageRef` (8-bit mask from `outlierGroupTrashList()`),
using `ensureOutliersLoaded`. **Kotlin:** `showTrash` + `trashOpacity` in `SequenceViewModel` (persist like macOS), auto-on
for Get from Trash, pass `includingTrash` everywhere, draw the mask, show `FrameInfo.num_trash_outliers` (RightPanel + E2).
Expose `includingTrash` in the MultiSelect sheet.

### D7. Remove/Keep cursor contradicts the click [K]

macOS: a click always toggles regardless of Remove/Keep (`G:OutlierGroupView.swift:148, 314-343`) and the cursor shows the
toggle (`:165-182`). Kotlin: Remove always removes, Keep always keeps (`FrameViewModel.kt:101-102`) — matching the help text —
but `ToolCursors.groupPointing` (`:33-41`) shows the toggle cursor. **Fix:** keep Kotlin's explicit set (it matches the shared
help text) and make the hover cursor show the tool's own action for Remove/Keep.

### D8. Information tool + outlier window [D+K]

macOS: Information click opens the outlier window showing only that group, selected, and turns off other highlights
(`G:OutlierGroupView.swift:249-288`). Table is sortable, multi-select (selection highlights groups on the frame), has 35
optional decision-tree feature columns with a column chooser (Select all / Clear all) (`G:OutlierGroupTable.swift`,
`G:OutlierWindowView.swift:61-160`, `G:OutlierWindowViewModel.swift`). Title "Outliers for frame N".
Kotlin: Information only highlights (`FrameViewModel.kt:103`), never opens the window, nothing clears the highlight.
`OutlierWindowView.kt` lists every group of the current frame, fixed columns, no sort, single select; header uses
`current + 1` while the app is 0-based (`FrameImageView.kt:42`); `score` only filled for classifier decisions
(`D:handlers/OutlierHandlers.swift:254-256`).
**Daemon:** `Outlier.GetFeatures { session_id, frame_index, repeated group_ids } → repeated { group_id, map<string,double>
features, double classification }` using `decisionTreeValueAsync` over each `OutlierGroupFeature` case and
`classification(of:)`. **Kotlin:** `infoRows: StateFlow<List<Int>?>` in `SequenceViewModel`, set by Information click/drag
(D1), opens the window; rebuild the window as a sortable, multi-select table with a column chooser (persist chosen
columns); selection set shared with the edit overlay; title 0-based "Outliers for frame N". Window shortcut: see E10.

### D9. Outlier window Hough-line panel [D+K] — low priority

macOS: for one selected group, a Hough-line candidate table; selecting a line sets that group's line; finder settings
editable (`G:OutlierWindowView.swift:44-59, 164-354`). **Daemon:** `Outlier.GetLineCandidates`, `Outlier.SetLine`,
`Debug.GetHoughLineFinderArgs` / `SetHoughLineFinderArgs`. **Kotlin:** panel under the table when exactly one row is selected.

### D10. Smaller edit-view additions [K]

- Outlier, trash and frame opacity sliders (`G:RightPanel.swift:245-265`; frame opacity dims the image under black,
  `G:FrameEditImageView.swift:167-215`). Persist like macOS.
- Streak line through hovered/selected group, white α0.33 width 8, or "Calculating line"/"No line"
  (`G:OutlierGroupView.swift:208-226`); `OutlierGroup.line` is already sent.
- "Loading outliers for this frame" indicator (`G:ProgressBars.swift:11`, `G:BottomRightView.swift:198-205`);
  `FrameViewModel.loading` exists, unused.
- Selection box colour per tool (red, green, gray, yellow, pink, mint, blue, purple — `ISVM:2447-2467`).
- Remove the ~300 ms single-click latency caused by double-click detection (`FrameEditView.kt:149`): act on single click
  immediately unless the tool is one where double-click zoom conflicts (e.g. only treat double-click as zoom in NONE/pan).
- "Multi Choice" toggle in RightPanel (`G:RightPanel.swift:128-133`): with it on, tapping any decided group with any tool
  opens the multi-choice sheet (`G:OutlierGroupView.swift:145`).
- Multi sheets: show the per-option summary lines (`ui.overlap.*`, `ui.area.*`); keep the selection rectangle visible while
  the sheet is up; after MultiSelect, re-render affected frames (via A1/A2) like macOS (`G:MultiSelectSheetView.swift:266-272`).
- Pointing cursor during multi-tool rubber-band drag (known leftover).

---

## Section E — Panels, transport, filmstrip, grid

Kotlin: `K:ui/sequence/{LeftPanel,RightPanel,BottomControls,Filmstrip,ScrubSlider,SequenceScreen,SequenceViewModel}.kt`,
`K:ui/sequence/grid/*`, `K:ui/app/{StarMenuBar,KeyHandling}.kt`.

### E1. Processing status in every mode [K]

macOS bottom-right shows spinner + "N frames processing" + red Stop in edit and scrub (`G:BottomRightView.swift:101-118,
328-345`); LeftPanel's top button becomes **Status**, reopening a dismissed modal (`G:LeftPanel.swift:12-39, 235-252`).
Kotlin: cancel only in LeftPanel (edit) and the modal; `dismissProcessingModal` is one-way (`SequenceViewModel.kt:166`);
`reprocessSelected` (`:291-294`) doesn't re-arm the modal. **Fix:** `reopenProcessingModal()`; Status button while
processing; status cluster in `BottomControls.kt` (spinner, count of in-progress frames from `frameStates`, red Stop);
`reprocessSelected` via `startProcessingRun`.

### E2. Bottom status read-outs [K]

macOS (`G:BottomRightView.swift:81-99, 188-255, 262-275`): purgatory / waiting-to-save / saving counts; "frame is
<state>" in state colour; loading-outliers indicators; will-remove / will-keep / undecided / in-trash counts; ⚙ settings
button. Kotlin collects `savingState` and `outlierLoadState` but never shows them. **Fix:** `BottomStatus` composable in
`BottomControls.kt` from A1's saving states, frame state, `FrameInfo` counts (incl. trash, D6), gear → `app.openSettings()`.

### E3. RightPanel additions [K]

- **Fast-skip amount** picker 0–50 + per-mode description (`G:RightPanel.swift:38-95`); Kotlin hardcodes 20
  (`SequenceViewModel.kt:526`, also in the "Back 20 frames" tooltip). Persist like macOS.
- **"Re-process the next N frames"** with a redo-type picker (`FrameReprocessingType`), N editor, detection-type picker
  (`G:RightPanel.swift:308-358`) → `Processing.ReprocessFrames(cur..cur+N-1, type)` (`REPROCESS_ALL_HORIZONS` exists);
  detection type via `UpdateConfig` (A17).
- **"Render Updates"** (`:361-374`) → A2 render; disabled when no outliers loaded.
(Show Trash → D6; opacity/zoom/full-res → D10/D2/D3; Multi Choice → D10; horizon toggle + refine button → B7/B1;
log-to-file → H8.)

### E4. Per-frame neighbour and clean-method overrides [D+K]

macOS: per-frame aligned/static neighbour override editors with Reset (`G:RightPanel.swift:614-765`, VM `ISVM:840-935`);
changing a neighbour override recomputes the merged horizon or invalidates and reprocesses star alignment
(`ISVM:794-937`); clean-method label "Default"/"Custom" (`G:RightPanel.swift:449-456`).
**Daemon:** `Mapping.protoConfig` / `applyExpertConfig` (`D:Mapping.swift:193-330`) never map existing proto `Config` fields
9–11 (`aligned_neighbor_frame_overrides`, `static_neighbor_frame_overrides`, `pixel_replacement_overrides` — check exact
names); `Frame.SetCleanMethod` changes memory only (lost on resume). Map all three both ways; persist in `SetCleanMethod`;
add `Frame.SetNeighborOverride { session_id, frame_index, kind (ALIGNED|STATIC), oneof { int32 count; bool clear } }` that
runs macOS's invalidation (move `invalidateStarAlignmentIfExists` / `recomputeMergedHorizonIfExists` logic into StarCore if
gui-only); add `bool clean_method_overridden` to `FrameInfo`. **Kotlin:** editors + Reset + Default/Custom label in RightPanel.

### E5. LeftPanel parity [D+K]

- Top button: macOS "Process frames" opens the settings sheet and is disabled when nothing is left
  (`G:LeftPanel.swift:20-39, 213-252`); Kotlin "Process All Frames" starts immediately. Match macOS.
- "Render video from N frames", enabled only when every frame is complete (`:274-300`); Kotlin only via Export menu.
- 3-colour progress bar complete / processing / unprocessed (`:597-637`).
- Expandable per-`FrameProcessingState` stats breakdown (`:465-520`) from `frameStates` (A7).
- Alignment chart (C2).
- Operation-queue table (step × state counts, `:304-413`) — from F1's `StepProgress` event.
- "Show" list: original / final / userHorizon with an expander for every mode that exists (`:522-562`). Extend proto
  `FrameViewMode` (`star.proto:273-278`) with horizon, mergedHorizon, userHorizon, starAligned, failedStarAligned,
  earthAligned, failedEarthAligned, blobs, removeMask, autoProcessed, autoSelectiveProcessed, selectiveProcessed, final
  (keep existing numbers) and `Mapping.frameViewMode`.
- Fix the "Frame ${current+1}" label (E9).

### E6. Filmstrip parity [K]

macOS (`G:FilmstripImageView.swift`): shift/⌘-click selection (`:191-210`), reprocess context menu (`:212-259`), horizon
overlay (`:116-134`), loading spinner while outliers load (`:42-47`), "show frame N" tooltip. Kotlin `Filmstrip.kt:118` only
`vm.select(index)`; thumbnails load once (`:89`) at preview size. **Fix:** reuse GridView's pointer-modifier selection,
`ContextMenuArea` and overlay Canvas; request thumbnail size (D3); refresh on `ImageSaved` (A11).

### E7. Playback [K]

- Restore the previous interaction mode on stop (macOS `previousInteractionMode`, `ISVM:3335, 3402`; Kotlin forces SCRUB,
  `SequenceViewModel.kt:448, 466-470`).
- Prefetch ~30 frames ahead in the **displayed** view mode (`ISVM:3408`); Kotlin prefetches 3 in `VIEW_ORIGINAL`
  (`:537-544`) while showing `viewMode`, and cancel-previous `loadPreview` (`:498`) drops slow frames.
- Space always plays forward (macOS play button forces forward, `G:VideoPlaybackButtons.swift:94`); Kotlin's Space calls
  `togglePlayback()` keeping reverse (`StarMenuBar.kt:52`).
- Frame timing: subtract time already spent instead of a fixed sleep.
- "Preview first" (`AppViewModel.kt:219-226`) must call `startPlayback()` forward, never toggle it off (macOS
  `ISVM:2755-2763`).

### E8. Navigation cycles within a multi-frame selection [K]

macOS `transition(numberOfFrames:)` wraps through the sorted selection when >1 frame is selected (`ISVM:3234-3240`,
`2860-2895`); Kotlin `next/previous` clamp (`SequenceViewModel.kt:248-249`). Apply to arrows and fast-skip.

### E9. Consistency fixes [D+K]

- **0-based frame numbers everywhere** (macOS `G:EditableFrameNumberView.swift:15,38`): Kotlin bottom bar shows
  `index+1 / count` (`BottomControls.kt:84-111`), LeftPanel "Frame ${current+1}", outlier window `current + 1`. Reject
  out-of-range input (don't clamp); Escape/blur cancels.
- **View-mode pills** greyed when the frame lacks that image (`G:BottomLeftView.swift:44-56`); mode and view pickers
  disabled during playback. Kotlin's are always enabled (`SequenceScreen.kt:107-112`).
- **Grid:** context menu only on selected cells with an "N frames" header (`G:GridView.swift:232-282`; Kotlin
  `GridView.kt:124-146` acts on the selection even when right-clicking outside it); state text in the state's colour, not
  always green (`GridView.kt:210`); orange for pending refinement (B1); GridRightPanel file-name row (new
  `FrameInfo.filename` field — daemon), state colour, Horizon set/pending row (`G:GridRightPanel.swift:117-133, 185-188`);
  scroll current item to the centre, not the top.
- **Scrub slider:** `ScrubSlider.kt:25` uses `steps = frameCount-2` (one tick per frame); use a continuous slider and round.
- **Bottom bar:** wrap to two/three rows on narrow windows (`G:BottomControls.swift:66-95`); hide the frame number while playing.
- **Tooltips** on transport `GlyphButton`s (`contentDescription` is never shown) — use `TooltipArea`.

### E10. Menus and keys [K]

Reference `G:StarCommands.swift:45-210`, `G:StarApp.swift:317-337`; Kotlin `StarMenuBar.kt:46-117`, `KeyHandling.kt:20-47`.
- Add Actions menu items: Find Outliers for this frame (`ReprocessFrames([idx], REPROCESS_OUTLIERS)` via
  `startProcessingRun`), Decision Tree All, DT Auto Only, Render This Frame, Render All Frames, Re-process this frame from
  the start. Add a LeftPanel button for Find Outliers too.
- "Toggle Side Panels" menu item (Tab may be eaten by focus traversal — verify at runtime; the menu item is the fallback).
- H item label becomes "Close Horizon Painter" while open (`G:StarCommands.swift:130-132`).
- `handleGlobalKey` must return false when Ctrl/Cmd/Alt are held (today Ctrl-R renders, Ctrl-Z skips back).
- Tool keys 1–8 work in every mode (still disabled when the frame's method doesn't use outliers); Kotlin only in Edit
  (`KeyHandling.kt:42`).
- S disabled during startup horizon painting (`G:StarCommands.swift:119-120`); see B6.
- Window shortcuts: macOS ⌥O / ⌥A / ⌥D / ⌥P; Kotlin Cmd/Ctrl+Alt+X / +A. Align to macOS on macOS; on Windows/Linux keep
  Ctrl+Alt+<letter> (plain Alt clashes with menu mnemonics) and document it in the menu labels.

---

## Section F — Startup, open and processing modal

### F1. Per-step progress in the processing modal [D+K]

macOS: one bar per step (horizon, merged horizon, star/earth keypoints, star/earth alignment, outliers, merge), each done
(green) / running (yellow) / queued, "N of M complete", tooltips, "Nothing to do", status line; steps derived from config;
measured against a baseline and `alreadyDone` (`G:ProcessingModalView.swift:74-164, 479-575`). Also: inline
frames-processed-concurrently editor (`:286-292`), `showProcessingWindow` pref (`ISVM:2603`), red Stop (`:458-467`), modal
re-arms on every run incl. reprocess-selected (`ISVM:3039`).
**Implement:** move `ProcessingSteps` / `ProcessingStepProgress` from the gui target into StarCore. Daemon: while a run is
active poll `frameGraphViewModel` (~4 Hz) and emit a new `ProgressEvent` arm
`StepProgress { repeated StepCount steps (type, queued, running, done, already_done); int32 graph_builds_completed }`,
baseline taken at Start. Kotlin `ProcessingModal.kt`: `StepsView`, concurrency stepper (`UpdateConfig` field 7 reaches the
running queue via `FrameGraphBuilder.onUpdate`), alignment chart (C2), `showProcessingWindow` pref (H4), red Stop.

### F2. "Where this sequence left off" panel on reopen [D+K]

macOS `SequenceProgressModalView` after opening a config: name, status line (complete / not started / partly processed),
"X of N frames complete", per-step bars surveyed from disk, one action (Render Video or Start/Finish Processing) + Close
(`G:SequenceProgressView.swift`; raised at `G:ViewModel.swift:428-431`; actions `ISVM:2630-2675`).
**Daemon:** move `SequenceProgressSurvey` into StarCore; `Sequence.GetProgressSurvey(SessionRef) → SequenceProgress
{ frame_count, frames_complete, repeated StepCount steps }`. **Kotlin:** `SequenceProgressDialog` shown from `onOpened` for
a config resume with no unfinished horizon selection; Finish → `requestProcessAll()`; Render → `openRenderVideo()`.

### F3. "Speed vs sharpness" (keypoint divisor) in the removal step [D+K]

macOS (`G:KeypointDivisorStartupView.swift`, embedded `G:StartupView.swift:473`): collapsible section, presets 1 / 1.5 / 2
with the recommended one badged, free entry 1 ≤ v < 8 applied per keystroke, warning at ≥ 4, explanation quoting frame MP,
RAM and concurrency; auto-expands when reduction is advised or value > 1; marks `keypointDivisorWasChosen`.
**Daemon:** `KeypointDivisorAdvice { reduce_recommended, recommended_divisor, threshold_pixels, image_pixels,
full_resolution_concurrency, frame_concurrency, physical_memory_bytes }` on `SessionInfo` (or `Sequence.GetKeypointAdvice`);
confirm `Mapping.applyExpertConfig` sets `keypointDivisorWasChosen` only when the field is present (`D:Mapping.swift:296-302`).
**Kotlin:** `KeypointDivisorSection` in `StartupPrompts.kt` writing via `updateConfig` before start. Strings exist
(`ui.speed_vs_sharpness`, `ui.preset_*`, `ui.keypoint_*`).

### F4. Loading view progress and a real Cancel [D+K]

macOS (`G:ImageSequenceLoadingView.swift:14-74`): circular progress "N frames loaded"/"All N frames loaded", "Examining
video", "N frames extracted", Cancel. Kotlin: spinner, or "current / total" for video; no Cancel (`K:ui/loading/LoadingView.kt:23-41`).
**Daemon:** `OpenSequence`/`OpenConfig` report `buildFrameGraph` progress (a streaming variant, or `OpenProgress` events);
`OpenVideo` honours client CANCEL via `withTaskCancellationHandler` (today `D:handlers/SessionHandlers.swift:61-85` ignores
it). **Kotlin:** progress + Cancel (sends CANCEL, returns to Initial); use existing i18n keys.

### F5. Pre-render prompt behaviour [K]

macOS sheet can't be dismissed by clicking outside; Yes is the default (Return) (`G:PreProcessingRenderPromptView.swift:28-31`).
Kotlin: scrim click silently cancels the start (`K:ui/dialogs/RenderPromptDialogs.kt:32, 75-77`); no Enter. **Fix:** scrim
no-op on the pre-render prompt; Enter = Yes on both prompts.

### F6. Memory-gated preview generation [D]

`Frame.GetPreview` (`D:handlers/FrameHandlers.swift:55-62`) runs `makeMissingImage` inline, outside the operation queue,
with no memory reservation — a grid scroll fans out many full-res decodes. macOS queues memory-gated, low-priority
preview/thumbnail jobs for every frame at open (`ISVM:2297-2355`). **Fix:** route on-demand generation through the
frame-graph builder's preview queue/memory gate (whatever `PreviewOp`/`ISVM` uses — move to StarCore if gui-only); add an
optional background pre-warm after open (thumbnails first).

---

## Section G — Settings, render and info dialogs

Kotlin: `K:ui/dialogs/ProcessingSettingsDialog.kt`, `RenderVideoDialog.kt`, `InfoDialog.kt`, `K:data/ExportRepository.kt`.
macOS: `G:ProcessingSettingsView.swift`, `G:RenderVideoSheetView.swift`, `G:InfoDialogView.swift`, `G:EditableNumberView.swift`.
Adding a `Config` property touches: gui view model / FocusedField / settings view, daemon `Mapping`, both protos, the Kotlin
dialog (and `ExpertFieldWiringTest`), and all 22 i18n catalogues.

### G1. "Settings contradict finished work" flow [D+K]

macOS: snapshot on sheet open (`G:ProcessingSettingsView.swift:712-720`, `ISVM:1716-1760`); red "already processed frames
have different settings" line (`:450-457`); Process Now relabels to **Update** (`:673-675`) which asks Yes/No, Esc = No
(`:730-740`); sets `Config.reprocessOnSettingsChange`; if running, cancel-wait-restart (`ISVM:1772-1784`); Process Now
disabled during a run unless the change contradicts finished work (`:686-687`).
Today Kotlin just `updateConfig`s; `reprocessOnSettingsChange` (default true, `SC:Config.swift:358`) isn't in the proto, so
every output-affecting change silently invalidates on the next run; a config that macOS saved with `false` can never
invalidate from Kotlin. `Session.startProcessing` ignores Start while running (`D:Session.swift:121`).
**Proto/daemon:** `optional bool reprocess_on_settings_change` on `Config`, applied in `applyExpertConfig`;
`Sequence.PreviewConfigChange(UpdateConfigRequest) → { repeated string stale_stages; bool contradicts_finished_work }`
computing `ArtifactInputs.current(from: proposed).staleStages(comparedTo: ArtifactInputs.current(from: snapshot))` against a
per-session snapshot taken at `Processing.Start`, applying the complete / user-modified / isProcessing rule
(`SettingsChangeState`); `Processing.Restart` = cancel-and-wait (A5) + start.
**Kotlin:** call PreviewConfigChange after each edit (debounced), red line, Process Now/Update button, AlertDialog with No as
dismiss/Esc; on answer set the flag, `updateConfig`, restart if running, else `requestProcessAll()`.

### G2. Memory budget setting [D+K]

macOS row edits `Config.maxMatMemoryFraction` 0.1–0.95 (`G:ProcessingSettingsView.swift:1982-2023`, `ISVM:1620-1625`;
used at `SC:FrameGraphBuilder.swift:107`). Add `optional double max_mat_memory_fraction` to both protos; `Mapping.protoConfig`
sets it; `applyExpertConfig` applies when present, clamped 0.1–0.95; bounded `DoubleField` in `MEMORY_FIELDS`
(`ui.memory_budget` exists); extend `ExpertFieldWiringTest`.

### G3. Clean-method change reloads frames and resets the tool [K]

macOS pushes the new effective method to every frame (`ISVM:749-767`) and resets the tool to none when the method doesn't
use outliers (`G:ProcessingSettingsView.swift:1854-1856`). Kotlin's cached `FrameViewModel.info` (`FrameViewModel.kt:61-63`)
keeps the old method (`RightPanel.kt:76`, `SequenceViewModel.kt:236-240`). **Fix:** after a successful `updateConfig` that
changes `cleanMethod`, invalidate all frame VMs (A11) and reset the tool if needed.

### G4. Settings dialog behaviour [K]

- Scrim click cancels and silently drops edits (`:58`) — make it a no-op (or ask). Save errors are swallowed (`:193`) — show them.
- **Enable/disable dependencies** (only GPU gating exists, `:146-156`): static neighbours disabled unless camera fixed
  (`:875`); Canny on/off disabled for sky-only (`:798`); Canny min/max and L2 disabled for sky-only or Canny off
  (`:760, 1207, 1283`); homography ε disabled for sky-only (`:1244`); reference smoothing and brightness refinement disabled
  for sky-only or fixed camera, sub-rows need the parent toggle, spike sub-rows need spike removal (`:1444-1803`);
  auto-preservation disabled when Selective (`:779`); detection mode disabled when auto-preservation is No (`:1842`) — but
  see `MACOS_GUI_BUGS.md` #5 and do it correctly (enabled whenever the method uses outliers). Implement as
  `ExpertField.enabled: (EditState) -> Boolean` evaluated against live edit state.
- **Numeric fields:** add `min`/`max` to `DoubleField` (Canny 1–300, ε 0–10, spike deviation 0.001–0.5, divisor 1–8, …);
  validate on change with an error state; disable Save while invalid; inclusive bounds (macOS's exclusive upper bound is a
  bug, see `MACOS_GUI_BUGS.md` #3); neighbour-frame max = sequence length, not 1000 (`:259`); give feedback on unparsable
  input (`:186-189, 360-365`).
- **Send only changed fields** — today Save resends everything, marking the keypoint divisor as user-chosen
  (`D:Mapping.swift:296-302`).
- Remember the "Show Expert Settings" toggle (`ISVM:1836`).
- Localize all labels; use macOS's "Fixed/Moving" camera motion picker instead of the "Tripod head was moving" toggle.

### G5. Help text on every setting [K + i18n]

macOS: ⓘ per row with long-form text, "Show info"/"Hide info" for all (`:459-489, 1888-2308`); enum rows show each option's
description in the info panel and help as a tooltip (`:1910-1975`). Most row texts are English literals in Swift (e.g.
`:806-809`); enum texts are keyed (`ui.sky_only_desc`, `ui.camera_fixed_help`, `ui.canny_yes_desc`, `ui.l1_norm_help`, …).
**Fix:** move the Swift literals into `en.json` + 21 translations (and switch the Swift view to the keys — a small,
behaviour-neutral gui edit); `ExpertField.helpKey`; info toggle per row; Show/Hide-all; `TooltipArea` for option help.

### G6. GPU section, device name, detection type [D+K]

- GPU section always visible and expanded outside expert mode (`:271-275, 501-530`); status names the device
  (`SC:Config.swift:416-421`). Add `optional string gpu_device_name` set from `GPUCapability.deviceName()`; use
  `ui.gpu_status_supported` / `ui.gpu_status_unsupported`. Kotlin today: expert-only with a generic line (`:128-167, 389-397`).
- Add `DETECTION_CUSTOM` to the picker (`:104-110` omits it, so a Custom config shows nothing selected).
- Remember the chosen detection type as the default for new sequences (`userPreferences.processingType`,
  `:1830-1836`) in `LocalPreferences` under the macOS key; seed `defaultInitialConfig().detectionType` from it.

### G7. Render video dialog [D+K]

Bugs:
- **Auto-start re-fires:** `LaunchedEffect(autoStart, encoder)` (`RenderVideoDialog.kt:128-129`); `autoStart` stays true,
  so changing codec/encoder after an auto-render starts another. Clear `renderVideoAutoStart` (add a setter in
  `AppViewModel`) when `doRender()` begins.
- **Ignores stored settings:** always first entry of each list — h264, 24 fps (`:79-88`) — and always sends explicit
  settings, so the daemon's stored-video fallback (`D:handlers/ExportHandlers.swift:132-138`) is never reached. A 29.97 fps
  import renders at 24 fps. Seed from `SessionInfo.source_video_info.settings` if present, else `config.video`, else the
  user's remembered choices; validate down the codec → encoder → pixel format/muxer chain, falling back to the first valid.
- **Clicking outside during a render** closes the dialog (`:60`) while ffmpeg keeps writing (`runFFmpegWithProgress`
  ignores cancellation, `SC:VideoConvert.swift:223`). Block the scrim while rendering; add a real **Cancel** that makes the
  daemon terminate the ffmpeg process on task cancellation.
- **Daemon default extension:** `VideoExport.defaultOutputPath` uses `muxer.rawValue` (`D:VideoExport.swift:90-92`) →
  `.matroska`/`.mpegts`; use `muxer.defaultFileExtension ?? muxer.rawValue`.
(The `processing.stop()` bug is A6.)

Features:
- Show the output file name before rendering, "Rendering <file>" during, "Successfully rendered <file>" with **Show in
  folder** (`Desktop.browseFileDirectory`, falling back to `Desktop.open(parent)`) and Dismiss on success, a separate error
  view on failure (`G:RenderVideoSheetView.swift:143, 155-192, 322`). Daemon: `Export.GetDefaultVideoPath` (or return the
  path in the first/last event — add `string output_video_path` to the terminal event).
- Descriptive info (`:201, 236-237, 252-316`): "Render video from N frames", total length (`frameCount / fps`), frame-rate
  description, codec description, encoder "raw [description]", pixel-format components/bits/bit depths, muxer description
  and extension; fps formatted with `%g`. Daemon: extend `CodecCaps`/`EncoderCaps`, add `PixelFormatCaps`,
  `MuxerCaps { name, description, extension }`, `FrameRateCaps { value, description }` (sources: `FFmpegCodec.swift`,
  `FFmpegMuxer.swift`, `FrameRate.swift`).
- **Custom frame rate** with a validated 0–1000 field (macOS `:205-234`; daemon already accepts any positive rate,
  `D:Mapping.swift:368`, `ExportHandlers.swift:139`; it drops Custom from the capability list, `ExportHandlers.swift:85-87`).
- **Remember** fps/codec/encoder/pixel format/muxer in `LocalPreferences` using macOS keys (`ISVM:131-149`).
- Move `rendering` out of the dialog's local state into a view model so H1 can see it.
- Localize: `ui.rendering_file`, `ui.frame_n_of_m`, `ui.successfully_rendered`, `ui.rendering_error`, `ui.frame_rate`,
  `ui.codec`, `ui.encoder`, `ui.pixel_format`, `ui.container`, `ui.total_length`.

### G8. Info dialog [K]

Tab names via `ui.about`, `ui.how_to`, `ui.detailed` (`InfoDialog.kt:111-115`); remember the selected tab in
`AppViewModel` (macOS `ViewModel.currentInfoType`, `G:ViewModel.swift:286`; Kotlin resets at `:120`); the Detailed text must
be verbatim from `G:InfoDialogView.swift:122-186` (Kotlin `:36, 72-108` is a paraphrase missing the "you can see … in edit
mode" lines; dropping the "LINK to source code here" placeholder is fine). Prefer catalogue keys for the body text if they exist.

---

## Section H — App shell

### H1. Close/quit confirmation and graceful shutdown [K]

macOS: Cmd-Q → "Work In Progress" Cancel / Quit Anyway (`G:AppDelegate.swift:11-31`); closing the main window asks and
unloads (`:51-71`); File ▸ Close → "Stop and Close" (`G:StarCommands.swift:153-169`, `G:ContentView.swift:87-120`); all use
`hasPendingWork` / `pendingWorkDescription` (`ISVM:280-299`): processing, rendering video, frames still saving. On quit it
clears its run marker and saves config (`G:AppDelegate.swift:39-46`).
Kotlin: `Main.kt:46` `onCloseRequest = ::exitApplication`; Close Session tears down at once (`StarMenuBar.kt:41-43` →
`AppViewModel.kt:562-569`); Cmd-Q not intercepted; `AppViewModel.shutdown()` (`:619`) never called — the JVM shutdown hook
kills the daemon (SIGTERM on mac/Linux; **hard kill on Windows**, leaving the run marker → false crash report next launch).
**Implement:** `SequenceViewModel.hasPendingWork` + `pendingWorkDescription()` (processing, render-all, render video (G7),
`pendingSaves` (A1)) using `ui.pending.*` / `ui.work_in_progress.*`; `AppViewModel` confirm state + `ConfirmCloseOverlay`;
`onCloseRequest = vm::requestQuit`; route `closeSession()` through the check; on macOS install
`java.awt.Desktop.setQuitHandler` that defers to the dialog. On confirmed quit:
`runBlocking { withTimeoutOrNull(5000) { vm.shutdown() } }` (sends `Daemon.Shutdown`, which with A1/A16 flushes saves and
clears the marker) then `exitApplication()`.

### H2. Warning routing like macOS [K, optional D]

macOS (`G:ViewModel.swift:168-279`, `G:ContentView.swift:44-84`): critical → modal alert once per kind; after OK, repeats of
that kind go to the banner; ordinary warnings → banner; banners for passing conditions (memoryPressure, lowSystemMemory,
footprintOverBudget — `SC:StarWarning.swift:165-174`) expire after 60 s, others persist until dismissed; reset on close
(`:365-375`). Kotlin: one latest-wins banner, red if critical, no expiry, no reset; a dismissed critical returns every 30 s
(`AppViewModel.kt:270-272, 489-493`; `StarApp.kt:78-85, 148-173`); version-mismatch and warning banners overlap
(`StarApp.kt:84, 89`). **Implement:** port `report(warning:)`, `acknowledgeWarning()`, `show(inBanner:)` and the expiry timer
into `AppViewModel`; `CriticalWarningDialog`; reset in `closeSession()`; stack banners in one top-centre column. Optional
daemon: `bool passing_condition` on `Warning` from `describesAPassingCondition` (preferred over copying the list).

### H3. Killed-run report with Restart Now [D+K]

macOS at launch collects abandoned run markers (`G:StarApp.swift:220-235`) and shows the critical alert with "Restart Now"
when the config exists (`G:ViewModel.swift:206-264`, `ISVM:2648-2660`); frame-state changes update the marker's progress
(`ISVM:2378-2384`). Daemon logs then deletes the markers before the transport exists (`D:Stard.swift:68-74`) and never
updates marker progress. **Daemon:** keep `marker.asWarning` + `restartable_config_path`; send them as `Star.Warning`
notifications right after `Daemon.Hello` (add `string restartable_config_path` to `Warning`), or add
`Daemon.GetAbandonedRuns`; update marker progress on frame-state changes; ensure the marker's config path is the file the
daemon actually writes (A14). **Kotlin:** H2's critical dialog gains a "Restart Now" button (`ui.restart_now`) →
`openConfig(path)` then `svm.processAll()` (no pre-render prompt, as macOS). Engine-down restart
(`AppViewModel.kt:574-598`) remembers whether processing was running and resumes it after reopening.

### H4. Preferences dialog [K]

macOS Cmd-, (`G:StarCommands.swift:172-176`, `G:ContentView.swift:151-407`): show horizon on main view, show horizon painter
instructions, skip render prompt, show processing window (+ alignment in processing window), processing type and frame rate
read-only. Kotlin: Cmd/Ctrl-, opens Processing Settings (`StarMenuBar.kt:62`); "Don't ask me again" (`RenderPromptDialogs.kt:39`
→ `AppViewModel.kt:208`) can never be undone. **Implement:** typed accessors in `LocalPreferences.kt` for every macOS key
(same names, same "unset" defaults; they're already preserved in `others`); `PreferencesDialog.kt` reusing `ui.*` strings,
on Cmd/Ctrl-, (File menu on Win/Linux, app menu on macOS); move Processing Settings to Cmd/Ctrl-Shift-, ; wire each pref at
its point of use (B7, B9, F1, C2, G6, G7).

### H5. New-release check [K]

macOS checks GitHub's latest release at launch (`G:ViewModel.swift:82-90`, `SC:ReleaseManager.swift:59-91`) and shows a
sheet with release notes, GitHub + download links, "Upgrade Later", "Quit Star" (`G:InitialView.swift:120-123`,
`G:NewReleaseSheetView.swift`). **Implement:** `util/ReleaseCheck.kt` fetching the same releases URL, Gson parse, same
three-part version compare against `HelloResponse.daemon_version`; per-OS asset matching for the desktop artifacts
(Star-Desktop .dmg / .deb / .exe — check current names in `.github/workflows/`; macOS's matcher only knows `star_app_` /
`star_cli_`, `SC:GitHubRelease.swift:46-64`); `NewReleaseDialog` on the Initial screen using `ui.there_is_a_new_release…`,
`ui.new_release_available`, `ui.release_notes`, `ui.quit_star`. Run once after the engine connects; fail silently offline.

### H6. i18n completeness [K]

- `setLanguage` (`AppViewModel.kt:141-144`) must also call `engine.client?.hello(clientVersion, Strings.currentCode)` so
  daemon-produced text (warnings, errors) switches language (`Daemon.Hello` is idempotent, `D:handlers/DaemonHandlers.swift:21-23`).
- Store resource keys (not text) in `AppScreen.Loading` and `InfoType`.
- Sweep hard-coded English: `Main.kt:47`; loading titles `AppViewModel.kt:524, 530, 535, 543, 579, 588`; engine badge +
  `shortEngineFailure` (`StarApp.kt:197-216`); `VersionCheck.kt:10`; `InfoDialog.kt:112-114`; `SequenceScreen.kt:115`
  ("Paint Horizon"); `RightPanel.kt:100-101` and all RightPanel bulk/clean/fast-skip labels; GridRightPanel section titles;
  transport tooltips; "Processed/Original" chips; all of `StartupPrompts.kt` (lines ~79-178, 289-299); `ProcessingModal.kt:57`;
  `FileChoosers.kt:50`; the settings and render dialogs (G4/G7). Use existing macOS keys wherever they exist
  (`ui.does_this_video_include_a_horizon`, `ui.mode_desc_*`, `ui.define_n_horizons`, `progress.frames_complete`, `ui.loading_x`, …).
- Drop-zone text shows a literal `\n`: `ui.drop_an_image_sequence_folder_video_or` is stored as `\\n` (`en.json:315`) and
  `Strings` doesn't unescape. Fix the catalogue entry in all languages (or switch to macOS's
  `ui.drop_a_video_an_image_sequence_or_an`).
- Add a grep-based test that fails on new string literals passed to `Text(` in `ui/` (allowlist for symbols/numbers).

### H7. Window title [K]

macOS "Star - <sequence folder name>" (`G:ContentView.swift:25`, `ISVM:2442-2445`, `ui.window_title`). Kotlin always "Star"
(`Main.kt:47`). Collect the screen; title = `localized("ui.window_title", folderName)` while a sequence is open, else
`localized("ui.star")`.

### H8. Debug log window [K, optional D]

macOS Window ▸ Debug Window (⌥D) (`G:StarApp.swift:282-287, 333-336`): live logs, level picker, filter, max lines, Copy,
Scroll to Bottom, Clear, log-to-file switch + level (`G:DebugView.swift`, `G:ViewModel.swift:13-44`, `G:StarApp.swift:239-259`);
RightPanel log-to-file + level (`G:RightPanel.swift:376-392`). **Implement:** ring buffer in `EngineState` fed by `util/Log.kt`
and `DaemonProcess.onStderrLine`; `ui/windows/DebugWindow.kt` from the Window menu reusing `ui.star_debug`, `ui.log_level`,
`ui.copy_to_clipboard`, …; show the engine log file path (`scratch/logs/stard.log`). Optional daemon
`Daemon.SetLogLevel { level, file_enabled, file_level }` for live level changes.

### H9. Blob Processing window [D+K] — low priority, developer tool

macOS Window ▸ Blob Processing (⌥P) (`G:StarApp.swift:264-268, 319-322`; `G:BlobProcessingView.swift`): detection-type
picker, per-step parameter editors and disable toggles, custom step sets. **Daemon:** new handler file with
`Blob.GetSteps { session_id, detection_type }` and `Blob.SetCustomSteps { … }` (mirror what `BlobProcessingView` reads and
writes in StarCore). **Kotlin:** `ui/windows/BlobProcessingWindow.kt`.

### H10. Initial-screen and misc cosmetics [K]

- "Welcome to Star v{version}" + "The starry timelapse airplane remover" (`G:InitialView.swift:61-67`); Kotlin shows "Star"
  + a different subtitle (`InitialView.kt:66-67`).
- Intro video aspect-fill, not stretched (`G:InitialView.swift:657`; `IntroVideoBackground.kt:67`).
- Recent rows titled by parent folder (A14); Load Config dialog filtered to `.json` (`G:InitialView.swift:237`;
  `FileChoosers.kt:57`).
- Stop buttons red (`G:ProcessingModalView.swift:458-467`).
- Initial defaults on open: macOS opens a new sequence in **edit** mode with the **original** view (`ISVM:1953-1955`);
  Kotlin scrub + processed. Match macOS.

### H11. Prevent idle system sleep while a sequence is open [K]

macOS disables idle sleep while a sequence is open (`ISVM:3588-3607`). Implement per-OS while processing or rendering:
macOS — spawn `caffeinate -i -w <jvm pid>`; Windows — `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)` via JNA
(or a tiny helper); Linux — `systemd-inhibit --what=idle` child process. Release on completion/close. Keep it best-effort
(log and continue if unavailable).

---

## Appendix — Out of scope / intentionally skipped

macOS-only mechanics with no cross-platform meaning, already covered by Kotlin equivalents, or dead code:
NSCursor push/pop (`CursorView.swift`); `TabCatcher`; `SystemButton`/SF Symbols; hidden zero-size shortcut buttons;
`MainWindowAccessor`; menu-bar status item; `.regularMaterial`; Swift Charts trackpad pinch (scroll wheel equivalent);
dead zoom variants (`OldZoomableModifier`, `ZoomableModifier`, `CocoaScrollViewFUCKED`); `readSize` geometry prefs;
in-process image-cache/`MatWrapper` stats in LeftPanel; commented-out harvester/classification timings; `ShrinkingButton`
press styling; App Nap disabler; multiple WindowGroup instances; the macOS client-side crash handler / run marker (lives in
the daemon for Kotlin — its user-visible report is H3); decision-tree classifier registration (daemon); macOS's
non-mirroring for Arabic/Urdu (Kotlin already matches).

macOS bugs found during the audit are recorded in `MACOS_GUI_BUGS.md`; do **not** port them into Kotlin.
