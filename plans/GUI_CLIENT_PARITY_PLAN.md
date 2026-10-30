# GUI client parity: findings and a shared Gherkin UI suite

**Status:** approved 2026-10-29. The owner took every default in §3 (D1–D14). Phase 3 has started on the findings that
needed no UI automation (§9 lists what is done, what is built but not yet exercised in a running app, and what is blocked);
Phases 0–2 are blocked on two things only the owner can do (§9.3).
**Audience:** the agent that implements it.
**Reads with:** `gherkin/README.md` (the existing corpus, generator and runners), `plans/CROSS_PLATFORM_DAEMON_DESIGN.md`
(the daemon contract), `CLAUDE.md` (localization; "Swift and Kotlin clients change together").

The macOS gui (`gui/star/`, SwiftUI, StarCore in-process) and the desktop client (`star-desktop/`, Kotlin/Compose, StarCore
through `stard`) are meant to be the same program with different plumbing. The last full parity pass ended on 2026-10-14
(commit `f93fb619`, the deleted `KOTLIN_CLIENT_PARITY_PLAN.md`). Since then about 48 gui and 31 desktop commits landed, about a
dozen of them on one side only. A six-way read of both clients on `develop` at `961a52f5` found ~120 differences; §4 lists
them. The owner has tested mostly the gui, so most of the work is the desktop catching up. But the audit also found gui
bugs that the desktop doesn't have, including two that lose or wipe the user's work.

The second half (§5–§7) proposes how to stop this recurring: one Gherkin UI corpus that runs on both GUIs against the
same expected results, built on the generator and runners that already exist.

---

## 1. Summary

* **Data/result differences (fix first):**
  * a new sequence starts Selective on the desktop and Automatic on the gui;
  * detection type comes from different places;
  * an outlier click toggles in the gui and sets in the desktop;
  * the gui loses decisions made on the last frame before Close;
  * the gui's multi-frame re-process wipes frames the user did not select;
  * the desktop overwrites a corrupt preferences file, and the gui drops the desktop's keys from it;
  * "Render All Frames" does different work in each client;
  * auto selective ends in a different state;
  * pixel threshold cannot be set from the desktop.
* **Flow differences:**
  * which panel holds which buttons;
  * the menu trees;
  * keys while painting, during playback and under panels;
  * dialogs' keyboard behaviour;
  * restart and update paths that drop the render prompt;
  * re-process/find-outliers running a whole graph run on the desktop.
* **Plumbing that causes drift:**
  * the desktop re-implements StarCore logic (`ProcessingHeadline.kt`, `WorkingLocation.kt`, `FrameState.isWorking`,
    `KeypointDivisor` presets), and the headline copy has already diverged;
  * the daemon has no `FrameObserver`, no pixel-threshold field and no custom resource limits;
  * it silently ignores a second `Processing.Start` during a run.
* **Why the existing tests did not catch any of this:**
  * every Gherkin feature drives a processing run and checks output files;
  * none asserts what is on screen or what a control does;
  * the two GUI runners already work around one difference: auto selective finishes by itself in the gui, while the desktop
    runner clicks Render All Frames;
  * the desktop harness renders `StarApp` only, so the window's key handler (`Main.kt:76`), the AWT menu bar
    (`StarMenuBar`) and the secondary windows cannot be tested at all.
* **Proposal:**
  * **Layer 0:** static checks that need neither app — an identifier registry both clients must implement, a command
    table, a hard-coded-string lint for Swift, shared test vectors for logic duplicated in Kotlin.
  * **Layer 1:** a `@ui` Gherkin corpus run by both GUI runners against **shared golden expectations recorded from the gui**:
    inline step arguments, probes, a relocatable pre-processed fixture, and a rule that runners differ only in mechanics.
  * **Layer 2:** daemon-level tests for the daemon-caused items.
  * Plus a side-by-side screenshot gallery for looks, which can never be asserted.

---

## 2. Rules for the implementing agent

* **Reference:** the gui is the reference for flow, wording and layout, unless §3 or a finding says otherwise. Where the gui
  is wrong (marked **FIX-S**), the fixed behaviour is the target for both.
* **Both clients change together** (CLAUDE.md). Every UI change lands on both sides in the same commit, with each side's tests.
  If a platform genuinely cannot do something, say so in the commit message and in §4's row.
* **Localization:** every new or changed string goes in **all 22 catalogues** with a real translation. Run `i18n/check.py`;
  the "same as English" count (~40) must not rise. Several gui gaps are hard-coded English (I1), and fixing them is part of
  this plan.
* **Kotlin cardinal rule (unchanged):** no StarCore-format serialization or pixel work in Kotlin. A fix that seems to need it
  is a new or extended `stard` RPC calling the same public StarCore API the gui calls. Logic that lives only in the gui target
  moves into StarCore, and both callers use it.
* **Proto changes are additive.**
  * Edit `daemon/proto/star.proto`.
  * Regenerate with `daemon/regen-proto.sh` (never a bare `protoc`).
  * `cd star-desktop && ./gradlew syncProto checkProtoSync`.
* **Building in a worktree:** see the memory notes `gui-worktree-build` and `star-desktop`.
  * Symlink `opencv/{include,lib,opencv2.framework}`, `StarDecisionTrees/{include,lib}` and `gui/videos` from the main checkout.
  * gui: `xcodebuild -scheme star` (never `-target Star`; the module is `Star`).
  * Daemon: `swift build -c release` only.
  * The cli Xcode project cannot link; use `swift build`.
* **One heavy job at a time on this Mac:** one xcodebuild, gradle build, StarCore/daemon test suite or star run at a time,
  never two GUI legs at once. Check `ps` first and stop Gradle daemons after. Parallel runs have logged the owner out before.
* **Processes get SIGSTOPped on this Mac.** A "hang" at 0% CPU may be state `T` (`ps -o stat`); `kill -CONT` only your own pids.
* **Commits:** one finding (or a tight group) per commit, message starting with its ID (e.g. `L3:`). Line numbers below were
  right at `961a52f5`; re-find by symbol when they drift.

---

## 3. Owner decisions (decided 2026-10-29: all defaults)

The owner took every default on 2026-10-29, so the Default column is the decision. Wherever §4 says "DEC Dn", apply that
row's default.

| # | Question | Default |
|---|---|---|
| D1 | Is the gui the reference everywhere unless a finding says FIX-S? | Yes |
| D2 | One click on an outlier group with **Remove** or **Keep** selected (E1): toggle the decision (gui) or set it to the tool's (desktop)? `ToolCursors.kt:35-46` calls the desktop's choice deliberate. | gui: toggle |
| D3 | **Multi** tool click with the Multi Choice switch off (E2): toggle (gui) or always open the multi-choice sheet (desktop, matches the tool's help text)? | gui |
| D4 | Processing settings sheet (P5): edits apply live with a Dismiss button (gui), or Cancel/Save/Process (desktop)? | gui (live), plus P6's fix and the desktop's inline red validation ported to the gui |
| D5 | When a decision is written (L3): on every edit with the re-render through the save queue (daemon), or on leaving the frame (gui)? | Every edit, in both; the gui also flushes on Close and counts unsaved frames as pending work |
| D6 | "Re-process this frame from the start" / "Find outliers for this frame" (L6): inline, no modal, honouring the right panel's reprocessing type (gui), or a full graph run with the modal (desktop)? | gui |
| D7 | "Render All Frames" (L4): a processing run with the pre-render prompt (gui), or finishing every frame from what is on disk (desktop)? | gui; the auto selective end state (L5) must be the same in both |
| D8 | The desktop's extra panel controls (Q4, Q6): bulk outlier buttons in the right panel, and Processing/Render blocks in the left. Remove them (menu only, as the gui did in `3d6b15f4`), or add them to the gui? | Remove from desktop |
| D9 | One menu tree for both (M14). Which items does the gui gain? | gui's tree, plus Process Current Frame, Cancel Processing, Processing Settings… (⇧⌘,), Render Video…, Play/Pause, Toggle Filmstrip, and File ▸ Open… items in **both**, always behind the work-in-progress confirm |
| D10 | Closing the main window (M5): unload the sequence and keep running (gui), or quit (desktop)? | macOS: gui behaviour in both. Windows/Linux: desktop may quit (documented platform exception) |
| D11 | Secondary windows (M6): new copy per ⌥-shortcut and survive unload (gui), or one toggled instance closed with the session (desktop)? | Desktop's behaviour (gui moves to single-instance `Window` scenes) |
| D12 | Desktop-only features: Decision Tree All Frames; Cancel during video render; Trash switch in the multi-select sheet; clickable decision column; remembered outlier-table columns; removable recents; Allow Earth Alignment / Max keypoint ops / Merge streaming MB in settings. Port to the gui, or remove? | Port all to the gui |
| D13 | Detection type (L2): the per-sequence `config.json` value (daemon), or the global preference applied to every sequence (gui)? | `config.json` per sequence; the preference seeds new sequences only |
| D14 | Fast advancement past frames whose outliers are not loaded (Q10): stop there (gui) or load and keep scanning (desktop)? | Desktop |

---

## 4. Findings

**ID prefixes:**

| Prefix | Area |
|---|---|
| S | Start screen and opening |
| P | Processing, settings, rendering |
| Q | Sequence screen |
| E | Outlier editing |
| H | Horizon painter |
| M | Menus, keys, windows, prefs |
| L | Logic underneath |
| I | Localization |

**Resolutions:**

| Code | Meaning |
|---|---|
| K→S | desktop follows gui |
| FIX-S | gui bug; fix the gui, desktop already right or follows |
| S←K | port desktop behaviour to gui |
| D | daemon change needed |
| DEC | §3 decision |

**References:** Swift paths are relative to `gui/star/`, Kotlin to `star-desktop/src/main/kotlin/com/star/desktop/`, daemon to
`daemon/Sources/stard/`.

**Which findings were re-checked:** I re-checked these against the code myself after the audit: L1, L2, L3, L5, L7, M2, M3, P1,
P4, Q4, Q6, E1. The rest come from reading both sides but no run. Items marked *(runtime)* need a run to confirm before fixing.

### 4.1 High: the user gets different data or a different result

| ID | Finding | gui | desktop | Resolution | Test idea |
|---|---|---|---|---|---|
| L1 | New sequence's default clean method | `.automatic(false)` (StarCore `Config.swift:220`); kept by the startup Close / ⚙ Advanced | `CLEAN_SELECTIVE` in `SessionRepository.defaultInitialConfig` (`data/SessionRepository.kt:97`) | K→S (drop the override; its comment predates the startup removal prompt) | open, Close the startup prompt, assert `cleanMethod` in config.json and in the settings sheet |
| L2 | Detection type source | Only in prefs and the global `constants`; `ImageSequenceViewModel.detectionType` (`:229`) never reaches `Config`, so config.json always says strong and `ArtifactInputs` never sees a change | Daemon applies `config.detectionType` on every open/update (`Session.swift:217,1122,1230,1277`); desktop sets the pref only on new sequences | DEC D13; FIX-S (gui writes `Config.detectionType`) | set pref Excessive, reopen a gui-written config in each client, assert the detection type in use and the Blob window picker |
| L3 | Decisions on the last-edited frame lost on Close (gui) | Edits are queued for save only on leaving the frame (`FrameEditView.swift:83-104`); `ViewModel.unloadSequence` (`:449`) does not flush; pending-work check ignores changed-but-unqueued frames | Daemon writes on every edit (`Session.swift:850`, `OutlierHandlers.swift:378`) and flushes on close | FIX-S + DEC D5 | toggle a group, Close, reopen: the group's decision survives (also assert from disk) |
| L4 | "Render All Frames" | `processAll()` — a graph run with the pre-render prompt (`RenderAllFramesButton.swift`) | `Export.RenderSequence` → `finish()` on every frame, no graph, left-panel progress bar (`SequenceViewModel.kt:987`, `ExportHandlers.swift:18-60`) | DEC D7 (default K→S) | on a half-processed sequence: prompt appears, modal shows, output frames for unprocessed frames are real merges |
| L5 | Auto selective end state | Writes finals by itself, but its progress line never reads N/N | Every frame stops at "outliers ready for review" (0/N complete); the desktop Gherkin runner clicks `render.all.frames` to finish (`DesktopFeatureRunner.kt:306-312`); the gui runner watches the disk (`GuiFeatureRunner.swift:310`) | D + FIX-S (investigate both; same end state, same progress line); then delete both runner workarounds | `autoSelective…` features with no client-specific finishing step |
| L6 | Re-process a non-contiguous selection (gui) | `processSelectedFrames` passes min…max and `resetForReprocessing` runs on every frame in between (`ImageSequenceViewModel.swift:3154,3240`) | Daemon resets exactly the indices sent (`Session.swift:512`) | FIX-S | select frames 2 and 6, "re-process outliers", assert frame 4's decisions unchanged |
| S1 | Cancel a video import | `cancelLoading` only bumps a counter; the decode runs on and leaves the frames folder (`ViewModel.swift:352,626-651`) | Daemon stops ffmpeg and StarCore deletes the folder (`SessionHandlers.swift:124`, `VideoConvert.swift:131,168`) | FIX-S | cancel at ~10%, wait, assert no frames folder and no ffmpeg child |
| M1 | Corrupt preferences file | Refuses to save over it, keeps `.undecodable`, writes atomically (`UserPreferences.swift:237-291`, G5 fix `4f723d71`) | `LocalPreferences.read()` returns empty on a parse error and the next `edit()` rewrites the file with one key, non-atomically (`data/LocalPreferences.kt:192-220`) | K→S (port G5) | invalid JSON in prefs, flip a preference: file unchanged, `.undecodable` exists |
| M2 | gui drops the desktop's preference keys | `save()` encodes the whole struct, dropping unknown keys (`outlierTableColumns`) and writing back stale values for keys the desktop changed meanwhile (`UserPreferences.swift:278`) | Re-reads and merges, writing only its own keys (`LocalPreferences.kt:209`) | FIX-S (merge-on-save) | prefs with a foreign key, toggle any gui pref: foreign key still present |
| P1 | Processing headline during planning | `hasPlan` is true once this run's graph is built (`ProcessingModalView.swift:76`) | `hasPlan = report != null` (`ui/dialogs/ProcessingModal.kt:78`), ignoring the proto's `graph_built` (`star.proto:844`); says "Finishing up…" at the start of a run | K→S now; see L16 for removing the copy | `processing.headline` reads the planning text before `graph_built` |
| P2 | Pixel threshold | Expert row 0.001–10 plus right-panel slider (`ProcessingSettingsView.swift:528,864`, `RightPanel.swift:584`) | No control; no proto field | D + K→S | expert settings snapshot contains `settings.pixelThreshold` |
| P3 | Typed numbers dropped (gui) | `EditableNumberView` commits only on Return; losing focus keeps the text but not the value (`EditableNumberView.swift:79-125`) | Applies typed text on Save/Process; invalid input goes red and disables both | FIX-S (commit on focus loss) + DEC D4 | type a neighbour count, click Process without Return, reopen: value kept |
| M3 | Open a new source while processing (desktop) | No Open item; only via Close, which confirms (`StarCommands.swift:167-186`) | File ▸ Open… / ⌘O / Resume always enabled; `launchOpen` closes the session with no work-in-progress check (`ui/app/AppViewModel.kt:1000-1003`, `StarMenuBar.kt:36-44`) | DEC D9; confirm required in both | during a run, Open: confirm appears, run continues on Cancel |
| Q1 | View mode with no image | "Image not found for frame &lt;mode&gt;" placeholder and a `PreviewOp` to build it (`FrameViewModel.swift:232-290`) | Silently falls back through other modes (`SequenceViewModel.kt:1143-1167,1202`); grid/filmstrip too | K→S (daemon builds on demand where StarCore can) | unprocessed frame, view "final": the not-found text is shown |
| E1 | Remove/Keep tool click | Toggles (`OutlierGroupView.swift:125-160,314`) | Sets (`ui/sequence/FrameViewModel.kt:198-202`) | DEC D2 | Remove tool, click a red group: expected colour per D2 |
| E2 | Multi tool click, Multi Choice off | Toggles (`OutlierGroupView.swift:143-150`) | Always opens the multi-choice sheet (`domain/ClickRules.kt:23-28`) | DEC D3 | assert sheet shown or not |

### 4.2 Medium: different flow or controls

**Start screen and opening**

| ID | Finding | Resolution |
|---|---|---|
| S2 | Restart Now leaves the reopen panel up over the run (desktop): `onOpened` starts the survey (`AppViewModel.kt:1266`), `resumeProcessing` (`:920-927`) never clears it; also the engine-restart path | K→S |
| S3 | No post-render prompt after a Restart Now run finishes (desktop): `resumeProcessing` clears `awaitingProcessingPrompt` (`:924`), `handleProcessingDone` returns early (`:465`) | K→S |
| S4 | Return does not start processing on the startup Removal screen (desktop, `ui/dialogs/StartupPrompts.kt:152-181`); the gui's Start is the default button (`StartupView.swift:518`) | K→S |
| S5 | Desktop dialogs ignore Return/Esc and close on an outside click: video import (`VideoImportDialog.kt:70`), sequence location (`SequenceLocationDialog.kt:55`), change mode, post-render prompt, render dialog. One rule for both clients: modal, Return = default, Esc = cancel, no outside-click dismiss | K→S |
| S6 | A single `.JPG`/`.png` dropped on the start screen goes down the video path in the gui (case-sensitive, no png: `InitialView.swift:198-203`) | FIX-S |
| S7 | After a failed or cancelled video import the gui's next load shows "Examining video"/old ring (`isProbingImageSequence`/`isExtractingImageSequence` never reset, `ViewModel.swift:612,645`) | FIX-S |
| S8 | Start screen differs: labels, order, tooltips. gui: Learn about Star; Load Video / Load Image Sequence / Load Config; Open Recent menu. Desktop: About; Open Image Sequence… / Open Video… / Resume…; a recents list with ✕ to remove. Desktop opens a non-config recent as folder/video; gui opens every recent as a config (`InitialView.swift:70-121`, `ui/initial/InitialView.kt:73-203`) | K→S for labels/order/tooltips; DEC D12 for removable recents |
| S9 | Free space: desktop uses `File.usableSpace` (`domain/WorkingLocation.kt:33`), StarCore `volumeAvailableCapacityForImportantUsage` (`DiskSpaceCheck.swift:102`); the desktop shows a shortage the gui does not. Byte formatting differs too | D (daemon answers from StarCore `DiskSpaceCheck`), delete the copy |

**Processing, settings, rendering**

| ID | Finding | Resolution |
|---|---|---|
| P4 | Update settings during a live run: gui cancels, then `processAll()` re-asks the pre-render prompt (`ImageSequenceViewModel.swift:1868-1880`); desktop `restartProcessing` carries the old answer (`AppViewModel.kt:328-335`) | K→S |
| P5 | Settings sheet: live-apply + Dismiss (gui) vs Cancel/Save/Process (desktop) | DEC D4 |
| P6 | Clean method and detection type offered differently: gui basic column has Automatic/Selective, "Selective Auto Clean" expert-only, detection type expert-only with raw lowercase values; desktop has a localized 3-way and an always-visible detection row (`ProcessingSettingsView.swift:1730-1749`, `CleanMethod.swift:42-130`, `ProcessingSettingsDialog.kt:137-180`) | K→S for placement; FIX-S for the gui's hard-coded English (I1) |
| P7 | Settings only the desktop has: Allow Earth Alignment, Max keypoint ops, Merge streaming MB; memory budget always visible (gui only under Custom) | DEC D12 |
| P8 | Settings sheet layout: title key, two columns vs one, collapsed disclosure groups vs open, expert toggle as a button vs a switch, alignment row order | K→S |
| P9 | "Use of this Mac": gui has Full/Balanced/Light + Custom popover (pipeline depth, memory, CPU/GPU width, GPU duty, disk streams, QoS, IO) + "Limited by: X" refreshed every 5 s, in the right panel's Processing section (`RightPanel.swift:279,716-831`); desktop has four chips in the modal only, pipeline depth in the settings sheet, Custom does not pre-fill from the previous profile (`ProcessingModal.kt:253-276`, `Mapping.swift:485`) | D (proto fields for custom limits and governor status) + K→S |
| P10 | Refinement status "Clearing the renders…" stays for the whole run: daemon holds `status` (`Session.swift:552,770`); gui clears it once queued (`ImageSequenceViewModel.swift:1556`) | D |
| P11 | Superseded Process All: the desktop shows the post-render prompt (or auto-renders a partial video) at the re-process's end, because `stopRun(announce:false)` emits no cancel (`Session.swift:512`, `AppViewModel.kt:1220-1228`) | D/K |
| P12 | Video render: gui builds its own ffmpeg glob command (`ImageSequenceViewModel.swift:3673-3735`), with no cancel, and `isRenderingVideo` is never set true (`BottomRightView.swift:438`), so Process stays enabled and Quit doesn't warn. Desktop/cli use StarCore `VideoExport` with a concat list, cancel, pending work | FIX-S (gui uses `VideoExport`; the "two encoders" follow-up from the scenario matrix) |
| P13 | Modal Preview button: Return, hover help and white text missing in desktop (`4cee5050` not caught up) | K→S |
| P14 | Custom frame rate: gui resets to 24 and commits on Return only (0–1000); desktop keeps the current rate, applies as typed (0.01–1000) and validates inline | DEC (default desktop's, FIX-S) |

**Sequence screen**

| ID | Finding | Resolution |
|---|---|---|
| Q2 | Grid "Show" list: desktop is a fixed four (`ui/sequence/grid/GridLeftPanel.kt:49-54`); gui is original + final + every available mode (`GridLeftPanel.swift:89-102`, `9042fbda`) | K→S |
| Q3 | Star/earth aligned never offered on the desktop: `Mapping.availableModes` lists only files on disk (`Mapping.swift:64-70`); gui's `hasImage` includes on-demand ones (`FrameViewModel.swift:89-115`) | D |
| Q4 | Desktop right panel has controls the gui dropped: "Outliers (N)" ✕/✓/? line, Trash count, Keep All / Remove All / Clear Undecided / Decision Tree All / DT Auto Only / Decision Tree All Frames, "Selected #N", shortcut digits under tools; header key `menu.tools` vs `ui.tool` (`RightPanel.kt:122-160,433`) | DEC D8 |
| Q5 | "Use of this Mac" missing from the desktop right panel (see P9) | K→S |
| Q6 | Desktop left panel has Processing (process from here, current, reprocess (force), find outliers, cancel) and Render (current, all, progress bar) blocks; the gui's left panel is progress marker + Show: + Display (`ui/sequence/LeftPanel.kt:64-101`, `LeftPanel.swift:61-77`). The desktop Gherkin runner clicks `render.all.frames` here | DEC D8 (and fix the runner via L5) |
| Q7 | Playback frame rate: gui Display-section picker (1…90 fps list, edit mode only; `LeftPanel.swift:220-231`); desktop fps −/+ in the bottom strip, every mode (`BottomControls.kt:96-100`) | K→S |
| Q8 | Mode and view pickers: gui bottom-left "[edit\|scrub\|grid] with [original\|final] frames", hidden while playing (`BottomLeftView.swift`); desktop top bar with pills disabled (not hidden) while playing, plus a "Paint Horizon Reference" chip and engine badge (`SequenceScreen.kt:104-147`) | K→S (engine badge stays, daemon-only) |
| Q9 (also P3: the gui dropped a typed number that was not committed with Return) | Number fields (static merge, max zoom): gui tap-to-edit, Return commits (even unchanged, creating an override), focus loss reverts, field closes after commit; desktop always-open, focus loss commits, unchanged does nothing, keeps focus so digits/arrows go into it *(runtime)*, max zoom applies per keystroke (`EditableNumberView.swift`, `RightPanel.kt:352-385,474-488`) | One rule for every number field in both clients: Return or focus loss commits, Esc reverts, focus leaves after commit, an unchanged value is a no-op |
| Q10 | Fast advancement in outlier modes: gui stops at the first frame whose outliers are not loaded (`ImageSequenceViewModel.swift:3391-3456`); desktop loads and continues (`SequenceViewModel.kt:1020-1050`) | DEC D14 |
| Q11 | Filmstrip/grid outlier ticks may go stale after a second edit on the desktop: refetch only on index/state change (`Filmstrip.kt:118`, `GridView.kt:131`) *(runtime)* | K→S |
| Q12 | Kotlin grid badge reads "complete" on finished cells (gui shows none); turns orange while refinement pending (`GridView.kt:190-196`) | K→S |
| Q13 | Desktop grid shows outlier counts (zeros) before they are loaded; Horizon row placement and toggle order differ (`GridRightPanel.kt:93-100`) | K→S |
| Q14 | "N frames processing": gui counts running operations (`numberOfFramesProcessingNow`); desktop counts frames in working states. gui's scrub/grid "Processing N more frames" never counts down (`numberOfFramesProcessed` never updated, `BottomRightView.swift:333`) | FIX-S + D (daemon reports running-operation count) |

**Outlier editing**

| ID | Finding | Resolution |
|---|---|---|
| E3 | Information tool on an undecided group: gui marks it remove (falls into the toggle path before the Information check, `OutlierGroupView.swift:152-156`); desktop lists it | FIX-S |
| E4 | Multi-choice and "overlaps" multi-select: gui writes decisions but renders nothing (`MultiChoiceSheetView.swift:223-231`, `MultiSelectSheetView.swift:318`); daemon re-renders every frame in range (`OutlierHandlers.swift:139,178`) | DEC D5 (default: re-render in both) |
| E5 | Multi-select defaults: gui starts on Keep and remembers the last action; "some frames" N = 50, shared and remembered (`ImageSequenceViewModel.swift:666-680`); desktop Remove, N = 5, both reset each time (`ui/dialogs/MultiFrameSheets.kt:77,102-105`) | K→S |
| E6 | Outlier window from the menu: gui lists only rows the Information tool filled, so 0 groups (`FrameEditView.swift:448-466`); desktop lists every large group of the current frame and follows frame changes | FIX-S |
| E7 | Outlier table: desktop decision column clickable, column choice remembered, headers translated; gui's classification toggle is labelled with `ui.neighborlinedistancescore` (`OutlierWindowView.swift:156`) | DEC D12; FIX-S for the label |

**Horizon painter**

| ID | Finding | Resolution |
|---|---|---|
| H1 | Sky/Ground on open: gui always Sky, also after Reset and band selection (`HorizonPaintState.swift:96-100,157-161,642-649`); desktop keeps the remembered mode (`HorizonPaintState.kt:53-57`) | K→S |
| H2 | "Change frame?" after the band: gui clears strokes when the band completes, so no prompt until a refinement stroke; desktop's flag stays on from the band (`HorizonPaintState.kt:139,351-364`) | K→S |
| H3 | Painter on a frame still being extracted: gui waits ("computing"), then loads its saved horizon (`FrameEditView.swift:224-230`); desktop tries once and falls back to band selection (`HorizonPainterView.kt:155-167`) | K→S |

**Menus, keys, windows**

| ID | Finding | Resolution |
|---|---|---|
| M4 | Keys while painting: gui keeps ←/→/b/f/z/x live and asks "Change frame?" once paint has started (`VideoPlaybackButtons.swift`, `ImageSequenceViewModel.swift:787-797`); desktop swallows every global key (`ui/app/KeyHandling.kt:28`) | K→S |
| M5 | Keys during playback: gui's transport buttons are hidden so their keys do nothing; desktop's still move the frame | K→S |
| M6 | Keys under the reopen panel: off in the gui (`ImageSequenceViewModel.swift:404-407`), on in the desktop (only the modal blocks, `KeyHandling.kt:30`) | K→S |
| M7 | `H` in scrub/grid: gui sets the painter flag without switching to edit, so nothing appears and E/S/G/A/K/U/R/D/1–8 go dead (`StarCommands.swift:146-153`, `FrameView.swift:14-27`); desktop switches to edit first | FIX-S |
| M8 | `d`: gui any mode; desktop edit mode + outlier frames only (`KeyHandling.kt:50-54`) | K→S |
| M9 | Shortcuts when a secondary window has focus: desktop menu and key handler belong to the main window only (`Main.kt:73-78`) *(runtime)* | K→S |
| M10 | Main window close: gui unloads and keeps running ("Close Anyway", `AppDelegate.swift:54-74`); desktop quits ("Quit Anyway", `Main.kt:73`) | DEC D10 |
| M11 | Secondary windows: gui ⌥P/⌥O/⌥A/⌥D open a new copy each time (inferred), always enabled, survive unload; desktop toggles one, needs a session, closes on teardown | DEC D11 |
| M12 | Menu tree: different groupings, labels ("Outlier Information Window" vs "Outlier Table", "Paint Horizon Reference" vs "Paint Reference Horizon"), desktop-only items, tool items enabled under modal/painter on the desktop only; ⌘W unbound in the gui (inferred); Home/End desktop-only; Tab gated under modal/painter on the desktop only | DEC D9 |
| M13 | Blob window detection-type picker: gui sets only the global (no config, no pref); desktop writes both (`BlobProcessingView.swift:52-61`, `AppViewModel.kt:285-301`) | with L2 / D13 |

**Logic underneath (daemon-caused)**

| ID | Finding | Resolution |
|---|---|---|
| L7 | "Re-process this frame" / "Find outliers": gui inline (delete per reprocessing type, `findOutliersAndRender`, no graph, no modal); desktop `ReprocessFrames` (EVERYTHING/OUTLIERS) runs the graph with the modal and redoes alignment/horizon (`SequenceViewModel.kt:652-660`, `Session.swift:512-517`) | DEC D6 (default: daemon gains the inline path) |
| L8 | "Process from here to the end" during a run: gui supersedes (G3, `ImageSequenceViewModel.swift:3185-3205`); daemon returns success and does nothing (`Session.swift:376-377`) | D (supersede, or error) |
| L9 | Horizon refinement "Now" during a run: gui runs it alongside; daemon refuses (`Session.swift:724-731`) and the desktop then shows not-busy while the run goes on (`ProcessingRepository.kt:201-213`); desktop also disables Re-run during a run | D + K |
| L10 | Change a frame's processing mode: StarCore links the new final only when the frame has a `FrameObserver` (`FrameAirplaneRemover.swift:1756`); the daemon never sets one, so the frame is re-rendered 10 s later and left user-modified instead of complete | D |
| L11 | Settings snapshot ("what changed since the last run"): daemon takes it on every run including re-processes; gui only on Process All | D |
| L12 | Render dialog's starting codec/frame rate: gui from the config; desktop source video → remembered prefs → config | K→S |

**Duplicated logic (drift risk)**

| ID | Finding | Resolution |
|---|---|---|
| L16 | Kotlin copies of StarCore logic: `domain/ProcessingHeadline.kt` + `StepRateTracker` (already wrong, P1), `domain/WorkingLocation.kt` (already different, S9), `FrameState.isWorking`, `KeypointDivisor` presets | Move to the daemon where the data is (the report carries the headline and overall text); otherwise shared test vectors (§5.4) |

### 4.3 Low: wording, layout, cosmetics

Fix these as you pass. Each one is K→S unless noted.

**Start screen and opening**
* Drop-zone text and click-to-choose (S).
* Missing "File does not exist" on drop (desktop).
* Loading-screen title (full path vs name; "Examining video" vs "0 frames extracted").
* Reopen-panel REBUILD button label ("Finish" vs "Start Processing"); Esc closes the panel on the desktop only.
* New-release sheet keys, release choice, timing.
* Disk line when the probe fails.

**Sequence screen**
* "Alignment Done / Alignment Error" line (missing on the desktop).
* Transport buttons disabled at the ends (desktop only).
* Filmstrip toggle shown in scrub (desktop).
* Re-run Horizon Refinement disabled during a run (desktop, see L9).
* Grid default size and its label (0.30× vs 0.12×).
* Right panel width.
* Side panels start scrolled to the bottom (gui).
* Filmstrip scroll position.
* "Loading outlier groups" bar, filmstrip "fetching" spinner and `ui.tool_needs_extracted_frame` help (missing on the desktop).
* Change-mode dialog icons and keys.
* Modal steps edge cases ("…" vs "—"; "Nothing to do" alongside the extraction row).
* Render dialog codec label, row order and success view.
* Render-prompt hover help (missing on the desktop).

**Editing and painter**
* Edge-arrow click applies the current tool on the desktop.
* Information box includes trash (gui).
* Multi-select sheet titles and counts:
  * different title keys on each side;
  * the "after" count is one too many in the gui — the desktop's count is right: FIX-S;
  * "the next [N] frames" vs "Number of frames".
* Rectangle left after Cancel (gui: FIX-S).
* Painter Save label, failure messages (desktop only: S←K), "Apply to nearby" during startup, Sky/Ground colours, what is drawn under the painter.
* Double-click zoom target, zoom on resize.
* Tint resolution cap, frame-opacity dimming, line widths, box blend.

**Windows and preferences**
* Alignment window empty state, title, info button placement, zoom gesture.
* "Show horizon painter instructions" preference shows off when unset (gui: FIX-S).
* Status-bar item (gui only).
* Debug window default line count.
* Blob window "copy from" visibility.

### 4.4 Localization in the gui (I1, FIX-S)

The desktop uses catalogue keys where the gui still has English in code, which CLAUDE.md forbids:
* transport tooltips;
* mode picker labels (from `rawValue`);
* Show-list and mode-picker help;
* "Process … (new only)" (`GridView.swift:231`, `FilmstripImageView.swift:227`);
* `CleanMethod.titleText` and the change-mode Yes/No (`RightPanel.swift:430-441`);
* `FrameProcessingState.shortString` badges;
* painter "Next"/"Continue" (`HorizonPainterView.swift:810`);
* outlier-table headers;
* detection-type values in settings and the Blob window.

Add the gui counterpart of `star-desktop/src/test/.../NoHardCodedStringsTest.kt` so this cannot come back.

### 4.5 Checked and equal

The audit confirmed many areas match:
* video-import options and disk estimate;
* the startup question flow;
* the keypoint-divisor screen;
* the processing step rows and their time-left logic;
* the alignment section and window charts;
* the GPU group;
* cloud-aware merge;
* the reopen survey;
* area tools (razor/shovel/trash/extract);
* decision-tree arguments;
* outlier colours and hit-testing;
* painter keys and brush;
* horizon line kinds;
* warning routing and run-marker alerts;
* sleep inhibition;
* the work-in-progress definition;
* the processing-modal rework (`2425ac50` covered `72209eab`, `b93207eb`, `9679aee7`).

The gui-only commits `f7694b68` and `6b515a6b` were deliberately not ported, and their messages say why.

---

## 5. Testing: what exists and what is missing

### 5.1 What exists

`gherkin/` has one corpus, a generator (`star-gherkin-gen`, Ruby `gherkin` at generation time only), committed generated
entry points, and three runners:
* `cli/Tests/GherkinTests/CliFeatureRunner.swift`;
* `gui/starUITests/GuiFeatureRunner.swift` (XCUITest, launch-argument seams `-StarUITestOpenSequence`/`-StarUITestOpenVideo`,
  `HOME` and run-marker isolation);
* `star-desktop/src/gherkinTest/.../DesktopFeatureRunner.kt` (`runDesktopComposeUiTest` on `StarApp` with a real `stard`,
  offscreen, `user.home` isolation).

CI (`.github/workflows/gherkin.yml`) runs one job per (client, OS, feature) and guards against vacuous greens.

### 5.2 Why it cannot catch parity gaps

1. Every feature is a processing run checked by output files; no step asserts a control, a dialog, a key or a menu.
2. The runners adapt to client differences instead of exposing them (L5). Nothing forbids that today.
3. The desktop harness cannot see the window's key handler (`Main.kt:76`, `onKeyEvent = handleGlobalKey`), the AWT menu bar
   (`StarMenuBar`), or the secondary windows (separate `Window`s in `Main.kt`). The gui's XCUITest can reach all three.
4. Steps are fixed strings whose `{placeholders}` come from `params.json`, not from the feature text. A UI corpus needs many
   variants ("press k", "click `settings.process`"), which would mean one `steps.json` entry per variant.
5. Only 34 gui accessibility identifiers and 24 desktop test tags exist, all on the startup/import/progress path.
6. Each mac-gui feature takes 5–20 min, almost all of it processing at full size.

---

## 6. Proposal

### 6.1 Principles

* **One expectation, two clients.** A UI feature's expected results live in the repo, once, and both runners compare against
  the same files. When they differ, the gui's recording is the reference (D1) unless the feature says otherwise.
* **Runners differ in mechanics only.** A runner may differ in *how* it clicks, types or waits, never in *what* the user does.
  If a client needs an extra user action to reach the same state, the feature fails on that client. Add this rule to
  `gherkin/README.md`, and remove the L5 workarounds once L5 is fixed.
* **Assert what the user can see or what lands on disk.** Not internal state, except through the few documented probes (§6.4).
* **Fast.** `@ui` features run on a small fixture, mostly without processing, and many per job.
* **Known gaps are a ratchet, not a skip.** This follows the `gherkin/removal-baseline.json` pattern in a new
  `gherkin/ui/known-gaps.json`, one entry per (feature, client):
  * a failure listed there passes, and says so;
  * a failure not listed fails;
  * an entry that now passes fails the run until it is removed.

### 6.2 Layer 0: static parity checks (seconds, every PR, no app)

1. **Identifier registry**, `gherkin/ui/ids.json`: every id any UI step or snapshot uses, with an optional dynamic-prefix form
   (`videoimport.format.*`). `star-gherkin-gen` (run by `generate.sh` and the existing `generate-check` CI job) fails unless
   each id appears as `.accessibilityIdentifier("…")` under `gui/star` **and** `Modifier.testTag("…")` under
   `star-desktop/src/main`. This catches a control added on one side only.
2. **Command table**, `gherkin/ui/commands.json`: one row per menu command (D9) with:
   * `id`;
   * catalogue key for the label;
   * menu path;
   * shortcut per platform;
   * enablement as named predicates (`sessionOpen`, `notUnderModal`, `notPainting`, `editMode`, `frameUsesOutliers`, `notUnderReopenPanel`).

   Each client builds its menu from a data table (desktop: refactor `StarMenuBar` onto a `MenuModel`; gui: a `[StarCommand]`
   table `StarCommands` iterates). A unit test on each side asserts its table equals the JSON (`gui/starTests`;
   `star-desktop/src/test`).
3. **gui hard-coded-string lint:** a `starTests` counterpart of `NoHardCodedStringsTest` (I1).
4. **Shared test vectors** for any logic still duplicated in Kotlin after L16:
   * a Swift test evaluates StarCore's implementation over the inputs in `gherkin/ui/vectors/<name>.json` and checks the
     recorded outputs (`STAR_VECTORS_RECORD=1` rewrites them);
   * a Kotlin unit test reads the same file and checks its copy.

   Start with `ProcessingHeadline` (the P1 bug would have failed it), `DiskSpaceCheck`/`WorkingLocation`,
   `FrameState.isWorking` and the keypoint-divisor presets.
5. *(Advisory)* **Catalogue-usage report:** which `ui.*` keys only one client references. A raw count today is 198 gui-only
   and 145 desktop-only, but much of it is noise from dynamically built keys and enum-driven names. Useful as a CI summary
   with an allowlist, not as a gate.

### 6.3 Layer 1: the `@ui` corpus

**Generator changes** (`gherkin/StarGherkin/Sources/star-gherkin-gen/main.swift`, `Model.swift`, the Kotlin `Model.kt`):

* **Inline arguments.** In `steps.json`, `<name>` (or `<name:int>`) marks an inline argument matched against a double-quoted
  string (or a bare integer) in the feature text, e.g. `"text": "I press \"<key>\""` matches `When I press "k"`. Parsing
  stays at generation time: the generated `Step` carries `args: [String]` (Swift) / `args: List<String>` (Kotlin). Keep
  `{placeholder}` for params-file values.
* **Data tables**, carried as `[[String]]`, for list assertions ("the right panel sections are, in order: …").
* **Tags.** A `@ui` tag marks a UI feature; it must also carry `@mac-gui @desktop` (the generator enforces both: a UI feature
  on one client only is the thing this plan exists to prevent; `@ui-<client>-only` with a reason line is the escape hatch).
  Emit `gherkin/generated/features-ui-<client>.json`.
* **Scenarios.** Keep one Scenario per file. The existing rule exists because there is no state reset; a UI feature is short,
  so one launch per feature is acceptable.

**Fixtures** (new `test_data/datasets.json` entries; the owner uploads them):

* `ui_small`: ~8 frames of `a7sii_10` downscaled to about 1060×708 JPEG, horizon in frame, unprocessed. Build script
  `test_data/build_ui_small.sh` (`magick`).
* `ui_small_selective`: `ui_small` after one `star -c selective` run, with its `star_temp_*` and output directories and
  config.json, archived. Outlier ids are then fixed, so features can name "the largest undecided group on frame 3" and get the
  same group on both clients. The runner relocates it after copying:
  * rewrite the absolute paths in `config.json`;
  * rewrite any other file the Phase 0 spike finds holding paths, e.g. `artifact_inputs.json`;
  * then open it through Resume / Load Config.

  If relocation proves unreliable, fall back to producing it at setup time with the cli. The memory note says
  `--no-horizon` selective is deterministic on the crop; check that it is on `ui_small` too.
* Preference fixtures under `gherkin/ui/fixtures/prefs/` (valid with a foreign key; invalid JSON).
* A run-marker fixture for Restart Now scenarios. The gui-alert recipe in memory (`gui-alert-verification`) plants one; the
  desktop gets it from the daemon's Hello.

**Seams to add.** All are launch arguments or system properties; none changes behaviour without the flag.

| Seam | gui (XCUITest) | desktop (Compose test) |
|---|---|---|
| open a config | `-StarUITestOpenConfig <config.json>` (new; mirrors Load Config) | `vm.openConfig(path)` via the UI path, as the runner does for sequences |
| window size | `-StarUITestWindowSize 1400x1100` (new) | `runDesktopComposeUiTest(width, height)` (exists) |
| language | `STAR_LANG=en` env | `STAR_LANG=en` env |
| keyboard and menu | real (XCUITest `typeKey`, menu bar clicks by English title from `commands.json`) | **new test host**: the window content including the key handler moved from `Window(onKeyEvent=…)` to a root `Modifier.onKeyEvent` inside a `StarWindowContent(vm)` composable (same bubble phase; production uses it too), and menu commands invoked through the `MenuModel` by id after asserting `enabled` |
| secondary windows | real windows (`app.windows`) | the test host renders each open secondary window's content in a tagged pane `window.<id>`, driven by the same window list `Main.kt` uses |
| quit / app exit | real (`app.state`) | an injectable exit hook so "the app has quit" is observable |
| probes | `-StarUITestProbes YES` | `-Dstar.ui.probes=true` |

**Probes.** These are a small, documented set (`gherkin/ui/probes.md`), each an accessibility element / semantics node with a
canonical, language-free value. Both clients publish them from their own view model:
* `probe.frame` = `index=3;mode=edit;view=original;tool=remove;painting=false;playing=false`;
* `probe.outliers` = `remove=4;keep=2;undecided=1;trash=0;loaded=true`;
* `probe.run` = the existing `processing.progress` format plus `plan=built|planning`.

Steps match a subset of `key=value` pairs. Probes are for state that is drawn but not as text (colours on a canvas).
Everything else uses real controls.

**Per-outlier-group elements.** Each outlier group needs an element over its box, so a test can click it and read its decision:
* gui: `OutlierGroupView` is already one view per group; add `accessibilityIdentifier("outlier.<id>")` and
  `accessibilityValue("remove|keep|undecided|trash")`;
* desktop: groups are drawn on a `Canvas` (`FrameEditView.kt:260`), so add one invisible semantics node per group, positioned
  at the transformed bounds, with the same tag and `stateDescription`.

Then `When I click the outlier group "<rank>"` (e.g. `largest undecided`) resolves the id from the fixture and clicks the
element's centre on both clients.

**Snapshots.** These are the shared goldens. `Then the screen matches the snapshot "<name>"`:
* each runner collects every registry id present in the window(s) as `{present, enabled, selected, value, text}`;
  * gui: one `app.snapshot()` call, never per-element queries, because polling the tree starved the app in the scenario
    matrix;
  * desktop: `onAllNodes(hasTestTag)`;
* it compares that against `gherkin/ui/snapshots/<feature>/<name>.json`;
* a container marked `ordered` in `ids.json` (right-panel sections, menu items) also compares order;
* masks (`"*"`) cover version strings, paths, estimates and free space;
* `STAR_GHERKIN_RECORD=mac-gui` writes the golden from the gui run, which is then reviewed in the PR;
* the desktop never records.

Every snapshot step also saves a window PNG; see §6.6.

**Initial step vocabulary** (inline args in quotes):
* setup: `the app is started with no sequence`, `the preferences file is "<fixture>"`, `a fresh copy of the sequence {ui_sequence}`,
  `a processed copy of the sequence {ui_processed}`, existing setting steps;
* actions: `I open the copied sequence`, `I resume the copied sequence from its config`, `I click "<id>"`, `I press "<key>"`
  (`k`, `cmd+w`, `return`, `escape`, `right`), `I choose the menu command "<command>"`, `I type "<text>" into "<id>"`,
  `I go to frame <n:int>`, `I click the outlier group "<rank>"`, `I drag a box around the outlier group "<rank>"`,
  `I paint a horizon band`, `I close the window`, `I quit`;
* checks:
  * `"<id>" is shown` / `is not shown` / `is enabled` / `is disabled` / `has value "<v>"` / `reads "<catalogue key>"` (compared
    with en.json, args allowed);
  * `the dialog "<id>" is shown`;
  * `the probe "<name>" reads "<k=v;…>"`;
  * `the screen matches the snapshot "<name>"`;
  * `the sequence's config has "<field>" = "<value>"`;
  * `the saved decisions of frame <n:int> match the screen` (via a new `star-output-verify decisions` subcommand, which reads
    StarCore's outlier files in Swift; test tooling, not client code);
  * `the preferences file is unchanged` / `has "<key>"` / `has an undecodable copy`;
  * `the app is running` / `has quit`;
  * `<n:int> "<window>" windows are open`.

**Initial `@ui` features.** One per row, each covering the findings named. Write them first, red where the gap exists, with a
`known-gaps.json` entry.

| feature | covers |
|---|---|
| `uiStartScreen` | S8, low start-screen items (snapshot) |
| `uiNewSequenceDefaults` | L1, L2 |
| `uiStartupKeyboard` | S4, S5 |
| `uiVideoImportCancel` | S1, S7 |
| `uiCorruptPreferences` | M1 |
| `uiSharedPreferences` | M2 |
| `uiSettingsSheet` | P2, P3, P5–P8 (snapshots basic + expert) |
| `uiProcessingModalPlanning` | P1, P13 |
| `uiRestartNow` | S2, S3 |
| `uiUpdateSettingsMidRun` | P4, P11 |
| `uiRenderAllFrames` | L4 |
| `uiAutoSelectiveEnds` | L5 |
| `uiSequenceScreenLayout` | Q4–Q8, low layout items (snapshots in edit/scrub/grid) |
| `uiViewModeUnavailable` | Q1, Q3 |
| `uiGridShowList` | Q2, Q12, Q13 |
| `uiOutlierClicks` | E1, E2, E3 |
| `uiDecisionsSavedOnClose` | L3 |
| `uiMultiSelectSheet` | E4, E5 |
| `uiReprocessNonContiguous` | L6 |
| `uiReprocessCurrentFrame` | L7 |
| `uiProcessFromHereDuringRun` | L8 |
| `uiChangeFrameMode` | L10 |
| `uiHotkeysWhilePainting` | M4, H2 |
| `uiHotkeysUnderPanels` | M5, M6, M8 |
| `uiPainterOpens` | H1, H3, M7 |
| `uiMenuCommands` | M12 (enablement in each state, from `commands.json`) |
| `uiOpenWhileProcessing` | M3 |
| `uiWindowClose` | M10 |
| `uiSecondaryWindows` | M11, E6, M9 |
| `uiVideoRender` | P12, P14 |
| `uiNumberFields` | Q9, P3 |
| `uiTranslatedScreen` | I1: `STAR_LANG=de`, snapshot of the sequence screen; the de golden is recorded from the fixed gui |

### 6.4 Layer 2: daemon-path tests

Add these to `daemon/Tests/StarDaemonTests`, or to the gated `InteropIntegrationTest`, for each **D** item:
* `Processing.Start` during a run supersedes or errors (L8);
* `Horizon.RunRefinement` during a run (L9);
* `Frame.SetCleanMethod` leaves the frame complete with its new final linked at once (L10);
* `Mapping.availableModes` includes on-demand aligned images (Q3);
* the settings snapshot is taken only on Process All (L11);
* status text clears once refinement work is queued (P10);
* `stopRun(announce:false)` followed by a re-process does not end in a "done" that the client reads as the superseded run's (P11);
* the report carries the headline/overall text equal to StarCore's for the same inputs (L16).

These catch daemon-caused regressions in seconds, before any GUI leg.

### 6.5 CI

Add to `gherkin.yml`:
* `ui-mac-gui` (macos-15) and `ui-desktop-{linux,windows,macos}`, each building once and running **every** `@ui` feature in one
  job;
* the vacuous-green guard compares the executed count with `features-ui-<client>.json`;
* `known-gaps.json` is applied by the runners;
* the Layer 0 checks run in `generate-check` and in the unit tests:
  * desktop: in `kotlin-client.yml`, which already runs them;
  * gui: no CI job runs `starTests` today (it appears in `gherkin.yml` only as a reason for `ENABLE_TESTABILITY`), so run
    `-only-testing:starTests` at the start of the `ui-mac-gui` job.

The owner pushes; this environment's GitHub identity is read-only.

### 6.6 Screenshot gallery (advisory)

Each snapshot step saves `<feature>/<name>-<client>.png`. A small script (`gherkin/ui/gallery.py`) writes
`parity-gallery.html` with the two clients side by side per checkpoint. CI uploads it as an artifact. It is for the owner's
eyes only: colours, spacing and fonts cannot be compared mechanically between SwiftUI and Compose, and it never fails a build.

### 6.7 What this cannot test

* Exact pixels and visual design (the gallery only).
* OS file dialogs (seams bypass them; the location dialog is reached through drop or the seams that do not bypass it).
* Linux/Windows accessibility of the packaged desktop app (not needed: the desktop runner is in-process).
* Behaviour under memory pressure or with a real long run: the processing features remain the tool for that.

---

## 7. Phases

**Phase 0 — spikes (one agent, about a day).** Each spike ends in a yes/no plus measured numbers recorded in this file.
1. Desktop test host:
   * extract `StarWindowContent(vm)` with the key handler on a root `Modifier.onKeyEvent`, and confirm production still behaves
     the same (a focused text field still gets its keys);
   * `performKeyInput` on the root reaches it;
   * a `MenuModel` command can be invoked by id.
2. gui: `app.snapshot()` over the full window on `ui_small` returns all identifiers within 2 s; measure.
3. Fixture relocation:
   * build `ui_small` and `ui_small_selective`;
   * relocate a copy;
   * reopen in each client: all frames complete, outlier groups listed, ids identical.
4. Generator inline arguments and data tables, with the generated Swift and Kotlin compiling.
5. Run `uiNewSequenceDefaults` on both clients (expected: green on the gui, red on the desktop, which is L1) and record the time
   per feature on each.

The owner, once on this iMac:
```bash
sudo automationmodetool enable-automationmode-without-authentication
```
Then upload the two fixtures.

**Phase 1 — decisions and spec.**
* §3 answered (done 2026-10-29: all defaults).
* `gherkin/ui/README.md` written (rules from §6.1, probe formats, snapshot format).
* `ids.json`, `commands.json` and Layer 0 checks in place, failing where the clients differ.

**Phase 2 — write the corpus.** Every feature in §6.3, each red where a gap exists, with a `known-gaps.json` entry. CI wired.
At the end, `known-gaps.json` *is* the parity backlog.

**Phase 3 — close the gaps.** In this order:
1. §4.1;
2. the daemon items (with Layer 2 tests);
3. §4.2;
4. I1;
5. §4.3.

Each fix removes its `known-gaps.json` entry in the same commit, on both clients.

**Phase 4 — remove the processing runners' workarounds** (L5) and add the §6.1 rule to `gherkin/README.md`.

**Done when:**
* `known-gaps.json` is empty, apart from entries the owner accepted as platform exceptions with a reason;
* every @ui feature passes on mac-gui and all three desktop OSes in three consecutive CI runs;
* the gallery has been looked at by the owner.

---

## 8. Open questions found but not settled

These need a run, not more reading:
* whether ⌘W is unbound in the gui, and whether ⌥O opens duplicate windows (M11, M12);
* whether the daemon resends an unchanged `userModified` state after an edit (Q11);
* how a focused Compose `BasicTextField` treats digits and arrows (Q9);
* the desktop's Mac menu bar when a secondary window is focused (M9);
* whether `finish()` on a never-processed frame (desktop Render All Frames, L4) produces anything sensible;
* whether a Kotlin Cancel on a fresh sequence leaves a `config.json` beside the sequence (the daemon saves before frames load,
  `Session.swift:1119`);
* whether the gui's ffmpeg glob and `VideoExport`'s concat list give identical videos for the same frames (P12).

---

## 9. Implementation log

Started 2026-10-29 on branch `claude/gui-client-parity-plan-3b6676`. Commits begin with the finding's ID (`git log --grep '^L1:'`).

### 9.1 Done, with a test that fails without the change

Desktop: `./gradlew test`, green (668 tests after the ninth round).
gui: `xcodebuild test -scheme star -only-testing:starTests`, green (270 tests after the ninth round). Daemon: `swift test --filter` on the suites it touches
(`FinalImageSavedEventTests|ExpertConfigFieldsTests|MappingTests|SessionCloseTests|EnumParityTests|HorizonRefinementSessionTests|StepProgressReportTests|DispatcherTests|ProcessingSupersedeTests|SettingsChangePreviewTests`, 149 tests after L8/L11), green.
The daemon's whole suite (`swift test`, 312 tests, one skipped: the real-sequence run, which needs `STAR_REAL_SEQUENCE_DIR`; including the integration tests that spawn `stard`) is green after the ninth round.
`DispatcherTests.testTheExpectedMethodSurfaceIsRegistered` had been failing on `develop` since the video-extraction commit registered `Frame.Prioritize` and `Frame.GetEta`; both are listed now.
StarCore: `swift test` (the whole suite, 1617 tests) ran after the ninth round's L5 change (1605 before the merge with `develop`'s core-speed work, 1616 after it): all pass but `VideoConvertTests.testTheShippedToolsCanBeRunOnThisMachine`, which fails on this worktree and not on the change: it wants `external_binaries/bin/ffmpeg` to be star's own build (`-star` in its version) and the symlinked one is a stock ffmpeg 7.1.1. Filtered runs since (`ByteFormattingTests`, `StepRateVectorTests`, `LocalizationTests`, `FrameCleanMethodChangeTests`) are green. The cli was not run; the StarCore changes are additive (an optional callback, one new method) except L10, which removes a gate in `FrameAirplaneRemover.set(cleanMethod:)` that only the gui's callers could pass.

| ID | What changed | Test |
|---|---|---|
| L1 | desktop no longer overrides a new sequence's clean method (proto zero = automatic) | `InitialConfigBesideTest.theRestOfTheDefaultsAreKept` |
| M1 | desktop `LocalPreferences` keeps an unreadable file, writes `.undecodable`, keeps changes in memory, writes through a temp file and a rename; a blank file counts as no file (both clients) | `LocalPreferencesTest` (7 new) |
| M2 | gui `UserPreferences.save()` merges into the file: only the keys this process changed, objects member by member (recents) | `UserPreferencesMergeTests` |
| P1 | desktop headline uses the proto's `graph_built` | `ProcessingModalPlanTest` |
| P2 | `Config.pixel_threshold = 63` (proto, daemon in and out, clamped 0.001–10), desktop expert row with its help text. **The right-panel slider is not done.** | `ExpertConfigFieldsTests`, `ExpertFieldWiringTest`, `SettingsRulesTest` |
| L3 | gui: `Callbacks.frameEditedCallback` fires from `markAsChanged()`; the gui writes the frame's decisions and queues its save on every edit (what `Session.frameEdited` does); `FrameSaveQueue.flush` (StarCore) saves what is waiting, and `unloadSequence` calls it. E4 follows: every multi-choice/multi-select frame goes through `markAsChanged`. | it builds, and `UserPreferencesStoreTests` and `SettingsWiringTests` stay green; **the callback and the flush were not exercised on a real sequence** |
| L6 | gui re-process clears only the selected frames | `ReprocessClearingTests` |
| L2, M13 | gui `detectionType` is stored in the sequence's `config.json` (loader + `didSet`), set into `constants` when a sequence opens, seeded from the preference only for a new sequence; the Blob window picker also sets the preference | `SettingsWiringTests` (existing, pairs the loader with the writer) |
| E1, E2 | desktop toggles on a click for Remove, Keep and Multi (D2, D3); cursor shows the opposite | `ClickRulesTest`, `ToolCursorsTest` |
| E3 | gui Information tool no longer marks an undecided group for removal | build only |
| S1, S7 | gui cancels the video import task (StarCore's `decodeVideo`/`startVideoExtraction` stop ffmpeg and delete the folder on cancel), resets the probing/extracting flags on any exit, and a cancel is not reported as an error | build only |
| S6 | gui single-image drop is case-insensitive and includes png | `DroppedImageTests` |
| M3 | desktop File ▸ Open… / Resume… ask first when work is going (`CloseAction.OPEN`; strings `ui.work_in_progress.opening`, `ui.stop_and_open` in all 22 tables). **The gui has no Open items yet (D9).** | `PendingWorkTest` |
| M5, M6, M8 | desktop keys: transport keys do nothing while playing; no keys under the reopen panel; `d` in any mode | `KeyHandlingTest` (the key set only; `handleGlobalKey` needs the test host of §6.3) |
| M7 | gui `H` from scrub/grid switches to edit first | build only |
| H1 | desktop painter opens on Sky and Reset / band selection put it back; a new frame keeps the mode only when it has a horizon to refine | `HorizonPaintStateTest` |
| S4, S5 | desktop dialogs are modal (`modalScrim`), Return = default, Esc = cancel: video import, sequence location, change mode, multi sheets, render video (Esc only); startup Removal screen: Return starts processing. **The post-render prompt already did this.** | the existing Compose tests stay green; the key handling itself is not tested (needs the test host of §6.3) |
| P13 | desktop Preview button: Return, hover help, white right-aligned help text | build only |
| E5 | desktop multi sheets start on Keep, remember action, range and N (default 50, shared) | `MultiSheetMemoryTest` |
| Q2 | desktop grid Show list = original, final and every available mode | `ViewModesTest` |
| Q9 | desktop `numberFieldRules` (Return and leaving commit, Esc reverts, focus leaves) on the neighbour-count and max-zoom fields; gui `EditableNumberView` commits on focus loss and on disappearing, Esc reverts, unchanged is a no-op, focus leaves after commit | build only |
| Q12 | desktop grid shows no badge on a finished frame and no orange for a pending refinement | build only |
| H2 | desktop: completing the band clears `hasStrokes`, so "change frame?" starts with the first refinement stroke | `HorizonPainterDetailsTest.completingTheBandClearsTheFrameChangeFlag` |
| Q4 | desktop right panel: outlier counts, trash count, Keep/Remove/Clear buttons, the three decision-tree buttons and "Selected #N" are gone (D8); header `ui.tool`; no digits under the tools. Decision Tree, All Frames became a menu item | build; nothing tested the removed controls |
| M12 | desktop menu uses the gui's labels (`ui.close`, `ui.process_all_frames`, the window items, `ui.paint_horizon_reference`). **and the menus are the gui's tree** (File, Actions, Tools, Window; `commands.json` gives each command's `menu` and the menus' title keys; Language stays a desktop menu of its own, Preferences is in File off a Mac) | `CommandTableTest(s)`, including `everyCommandIsInItsMenuAndNoOther` on each side |
| D9, M3 | gui menus gain Open Image Sequence (⌘O), Open Video, Resume from config.json (behind the same work-in-progress question as Close, with a "Stop and Open" button), Process Current Frame, Cancel Processing, Processing Settings (⇧⌘,), Render Video, Toggle Filmstrip, Play / Pause, and Close gets ⌘W | `CommandTableTests`; **not run in the app** |
| E6, E7, D12 | gui outlier window lists the current frame's groups and follows the frame; the classification toggle has its own label; Decision Tree, All Frames works in the gui | build; **not run in the app** |
| Q10 | gui fast advancement loads a frame's outliers and keeps scanning (D14) | `FastAdvancementSkipTests` (the decision only) |
| P7, D12 | gui settings sheet has Allow Earth Alignment, Max Keypoint Ops and Merge Streaming MB | `SettingsWiringTests` (the new property); the rows are build-checked |
| Layer 0 | `gherkin/ui/commands.json` (menu commands both clients must offer, with `knownGaps`) checked by a unit test on each side; `gherkin/ui/vectors/processingHeadline.json` (StarCore's headline text, recorded with `TEST_RUNNER_STAR_VECTORS_RECORD=1`) checked against the Kotlin copy | `CommandTableTest(s)`, `ProcessingHeadlineVectorsTest(s)` |
| Layer 0 | `gherkin/ui/vectors/constants.json`: the disk-space ratio and the keypoint divisor choices (StarCore's, copied by hand into the desktop), the custom frame rate rule's cases and the playback speed list; each client's test reads it (`SharedConstantsTests` against StarCore and the startup prompt, `SharedConstantsTest` against the desktop's copies). `FrameState.isWorking` has no StarCore counterpart (it is the desktop's stand-in for "frames processing now"), so it has no vector | `SharedConstantsTest(s)` |
| P12 | gui Render Video uses `VideoExport` (the frames as a concat list of the files the sequence expects, no glob), `runCancellableFFmpegWithProgress`, holds `isRenderingVideo` for the render's whole length (Process off, closing asks first), removes a cancelled render's partial file, has a Cancel button, and closing the sequence stops it; no processed frames is a message (`ui.render_video_no_frames`, 22 tables) | `VideoRenderWiringTests` (source scan + the message in two languages); **not run on a real render** |
| Q14 (gui) | gui "Processing N more frames" counts the frames not complete (it counted from a number nothing set). **The desktop half (running operations, not working states) needs the daemon to report the count** | `VideoRenderWiringTests.testTheFramesLeftAreTheOnesNotYetComplete` |
| P14 | gui custom frame rate starts at the rate in force, applies as typed (0.01-1000, red + the existing "Enter a number from a to b" line, Render disabled while invalid) | `SharedConstantsTests.testTheCustomFrameRateRuleIsTheDesktops` and `SharedConstantsTest.theCustomFrameRateRuleIsTheGuis` (same cases), a source scan of the sheet; the sheet itself not looked at |
| M4 | desktop: under the horizon painter the arrows, b/f and z/x still answer (and `setCurrentIndex` asks "Change frame?" once paint has started); Home/End and the editing keys stay the painter's | `KeyHandlingTest.underThePainterOnlyTheFrameKeysAnswer` (the key set only) |
| H3 | desktop painter stays in "computing" until a video frame is extracted, then loads its saved horizon | `HorizonPainterWaitTest` (`awaitFrameExtracted`) |
| Q13 | desktop grid panel: outlier counts only when `FrameInfo.outliers_loaded`; Display toggles in the gui's order; the horizon's Pending/Set row under Mode in Processing | build; nothing tested it |
| Q8 | desktop hides the mode and view pickers while playing (it greyed them), and they are at the bottom left, "[mode] with [original\|processed] frames", at the start of the bottom row (they were in a top bar beside a Paint Horizon Reference chip that the right panel button and the menu already do: the chip is gone; the top bar is only the engine badge, which only the desktop has). The gui's pickers showed `rawValue`/`shortName`, English in every language: they read the catalogue now (`interaction_mode.*`, `ui.view_original`/`ui.view_processed`, new `ui.interaction_mode_help` in 22 tables), so the gui says "Processed" where it said "final" | `ModePickersTest`, `ViewModeNameTests.testTheBottomLeftPickersReadTheCatalogue`; the layout itself not looked at |
| Q7 | desktop playback speed is the gui's Display picker (1, 2, 3, 5, 10, 15, 20, 25, 30, 60, 90 fps) in the Display section; the bottom strip's -/+ are gone (`ui.fps`, `ui.transport_slower`, `ui.transport_faster` are now unused by both clients, left in the tables) | `SharedConstantsTest(s)` for the list |
| Q3 | `Mapping.availableModes` also lists the star/earth aligned images a frame can build (`canProduceAlignedImage`); `Frame.GetPreview` could not serve them (`ImageAccessor.load(.original)` returns nothing for a missing full-size file), so `GetFramePreviewRequest.build_if_missing` (additive) makes the daemon build the image first, one at a time; the desktop sets it only for the frame on screen (preview and full-size), not for thumbnails or the playback prefetch | `SessionCloseTests` (the offer, and when a build is needed, with stored homographies), `FramePreviewRequestTest` (the flag on the wire); **a build on a processed frame was not run** |
| Q1 | a frame with no picture in the view mode showing says "<mode> image not found for this frame" (`ui.image_not_found_for_frame`) in the main view, the grid cells (smaller type) and "N/A" in the filmstrip; the desktop no longer falls back through final / original / subtraction / validation. An aligned mode is asked for with `build_if_missing` (Q3); the picture on screen stays until it is built, with no "building" text | `ViewModeExactTest` (fails on the old fallback: it asked for SUBTRACTION and VALIDATION too); the cells are build-checked |
| I1 (view modes) | StarCore `FrameViewMode.longName` reads `view_mode.<case>` from the catalogue (it was English literals, so the gui's Show lists, blob window and the not-found line were English in every language) | `ViewModeNameTests` (English unchanged, every case differs in German) |
| Q11 | filmstrip and grid cells (and the grid right panel) draw the frame's counts and clean method from its `FrameViewModel.info`, which every edit updates, and fetch them again when `frameDataVersions` says the frame's data went stale; they kept a copy fetched at index/state change | `FrameInfoLiveTest` (an edit lands in `frameInfoFlow`; a refresh replaces what was held); the cells are build-checked |
| P10 | the daemon clears the refinement run's "Clearing the renders" line (`stepsQueued(generation:)`) once its operations are queued, as the gui clears `processingStatusText`; it stayed in every step report of the run | `HorizonRefinementSessionTests.testThePreparingLineGoesOnceTheRunIsQueued` (the clear, and that another run's does not); **the call after `enqueueHorizonRefinement` was not exercised in a run** |
| Layer 0 | `gherkin/ui/ids.json`: the ids a UI step may use (`accessibilityIdentifier` in gui/star, `testTag` in star-desktop). Each client scans its source for id-shaped literals in the registry's namespaces (so an id passed to a helper that tags the control counts; a Kotlin template is a family `x.*`); an id found and not listed, a listed id missing, or a closed `knownGaps` entry fails. It showed nine real gaps, all closed: the gui tags `process.frames`, `settings.process`, `processing.headline`, `processing.overall`, `startup.selecthorizon.yes`; the desktop tags `render.cancel`, `render.custom_frame_rate`, `render.done`, `render.error`. **The desktop's `:test` did not rerun when a file under `gherkin/ui` or the catalogue changed (gradle did not know it read them): both are inputs of `tasks.test` now** | `IdRegistryTest`, `IdRegistryTests` (a removed id and a closed gap fail the desktop one) |
| P6 | desktop settings sheet: Automatic / Selective in the main column; under Show Expert Settings, Selective Auto Clean (Yes/No, off while Selective is chosen; starts at Yes when the method reviews outliers, as the gui) then the detection type (off while the method does not review outliers); it was a three-way plus an always-visible detection row. `CleanMethodChoice` is pinned by the `cleanMethod` vector in `constants.json`. New `ui.selective_auto_clean` in 22 tables. The gui's `HighLevelCleanMethod`/`AutoPreservationMode` headings and Yes/No/Automatic/Selective were English literals in StarCore: they read the catalogue now. Their hover and description texts follow in the I1 row below | `SharedConstantsTest(s)` (the mapping), `ViewModeNameTests.testTheCleanMethodRowsAreTitledInTheUsersLanguage`; the sheet itself not looked at |
| I1 | gui: `DetectionType.localizedName` for the three pickers, the transport tooltips use `ui.transport_*`, "Process N (new only)" and the painter's Next/Continue use the existing keys | `NoHardCodedStringsTests` (the gui counterpart of the Kotlin lint, §6.2.3) |
| L10 | `FrameAirplaneRemover.set(cleanMethod:)` returned before linking the new final unless `observer?.cleanMethod == cleanMethod`; the gui sets its observer first (always true for it), the daemon's frames have none (`nil == method`), so the override was recorded and the old final stayed. The gate is gone (neither the config, which the gui writes first, nor the observer can say what the method was before). `Session.setCleanMethod` no longer calls `markAsChanged`/`frameEdited` (they left the frame "user modified" and rendered it again when its save timer fired ten seconds later): a frame at rest (complete, user modified, outliers ready) has the new method's image linked, or made, at once and the client is told the final changed; a frame a run has not reached, or is still in, only records the method | `FrameCleanMethodChangeTests` (StarCore, harness: three methods linked with no observer, with one, and `process: false`; all three fail on the old gate) and `FinalImageSavedEventTests` (daemon: linked, event sent, state stays complete, nothing queued; an unprocessed frame only records it; both fail on the old `setCleanMethod`). **Not run on a real sequence; the gui's path is unchanged except that it can no longer be skipped** |
| S2, S3 | a run picked back up (Restart Now, or the engine restart that carries a run on) opens without the "where this sequence left off" panel (`ResumedRun.showsProgressPanel`; the survey was launched by `onOpened` and `resumeProcessing` never closed it), and it ends with the post-render question unless the render prompts are off (`ResumedRun.asksAboutRenderingAtTheEnd`; `resumeProcessing` cleared `awaitingProcessingPrompt`, so `handleProcessingDone` returned early). The gui's `restartProcessing` does both | `ResumedRunTest` (the two rules; `AppViewModel` cannot be built without an engine, so a source scan that it uses them); **no run** |
| Q14 (desktop) | the status's "N frames processing" sums the step report's running operations (the gui's `numberOfFramesProcessingNow`); it counted frames in a working state | `OperationsRunningTest` (the sum, and that the status reads it) |
| Q5 | the desktop right panel's Processing section shows the same "Use of this Mac" control as the modal (Full, Balanced, Light, Custom), between the neighbour count and Render Updates, as the gui does | build; the panel not looked at |
| P8 (part) | the desktop settings sheet's header is the gui's sentence (`ui.choose_from_the_following_options_to_let`), and the alignment group lists its rows in the gui's order (keypoint divisor, allow earth alignment, debug images, then homography smoothing). **Not done: two columns, the collapsed disclosure groups, the expert toggle as a button** (layout that needs looking at) | `SettingsTitleTest`, `AlignmentFieldOrderTest` (both read the gui's source); the sheet not looked at |
| S8 (part) | the desktop start screen: "Learn about Star", then Load Video, Load Image Sequence, Load Config, each with the gui's hover text, and the Recent list headed "Open Recent" (it said About Star, Open Image Sequence…, Open Video…, Resume…, with no hover texts). `gherkin/ui/vectors/startScreen.json` lists the controls in order. **Not done:** the gui's Recent is one "Open Recent" button and the gui opens every recent as a config where the desktop opens a non-config recent as a folder or video; the removable recents (D12) are not in the gui | `StartScreenTest` (reads the view's source against the vector, and that the texts are translated), `StartScreenTests`; the screen not looked at |
| L8 | `Processing.Start` while a run is going stops it (not announced as cancelled) and starts the new range, as the gui's `processFrames` does; it returned success and did nothing (`ProcessingHandlers.begin`). `Session.setNeighborOverride`'s own single-frame start still leaves a run alone (the gui's supersedes, which drops the user's whole run for one frame) | `ProcessingSupersedeTests.testAStartDuringARunSupersedesIt` (a real run over four tiny frames; reads the generation numbers, so no timing); **not run in the desktop** |
| L11 | the daemon takes the settings baseline ("what changed since the last run") only when a run covers the whole sequence, as the gui does in `beginProcessing`; it took it at every run, a one-frame re-process included | `ProcessingSupersedeTests.testOnlyARunOfTheWholeSequenceResetsTheSettingsBaseline` |
| P11, P4 | `RenderQuestion` replaces `AppViewModel`'s two flags (`autoRenderAfterProcessing`, `awaitingProcessingPrompt`): the answer is armed for the run number Process All starts (`ProcessingRepository.runsStarted` counts every run that begins: start, restart, granular reprocess, a refinement the daemon began) and the question is put only at that run's end, as the gui's `handleProcessingDone` does for Process All. A re-process, process from here or settings restart that took the run's place no longer ends with the prompt or a video of a partial sequence rendered unasked (P11). A settings change over a live run stops it and asks again (the gui's `cancelProcessing` then `processAll`), or restarts in one step when the question is off (P4). "Don't ask again" with "render after" now renders, as the gui does (it did nothing) | `RenderQuestionTest` (the state machine; a source scan that the view model uses it and that the settings path stops then asks), `ProcessingRepositoryTest.everyRunThatBeginsIsTheNextOne`; **no run: `AppViewModel` cannot be built in a test, so the wiring is read, not run** |
| L9 (desktop half) | a horizon refinement the daemon refuses during a run (it still does: the gui runs it alongside, which needs more than a flag in the session's single-run model) no longer clears the busy flag and the step bars of the run that is going (`ProcessingRepository.startClaimedRun` puts back what was showing when none began or the ask failed) | `ProcessingRepositoryTest.aRefusedClaimedRunLeavesTheRunThatIsGoingShowingAsGoing` |
| M9 | every desktop window (the outlier table, alignment, blob and debug windows) carries `StarMenuBar`, so the menu and its shortcuts work with any of them focused; there was no menu at all there. The plain keys (arrows, letters) stay the main window's, as in the gui | `MenuInEveryWindowTest` (reads `Main.kt`: Compose has no window test host, §6.3); **not run: whether a Mac shows the menu of the focused window was not looked at** |
| E1, E2 (Layer 0) | `gherkin/ui/vectors/clickRules.json`: the decision a click leaves (five starting decisions) and what a click on a group does for every tool with the Multi Choice switch on and off, on a decided and an undecided group (apply the tool, or open the multi-choice sheet). The gui's tap handler is `OutlierGroupView.groupClick` and `decisionAfterClick` now, plain functions, so it can be checked; the desktop's `ClickRules.groupClick` and `OutlierDecisions.toggled` are held to the same file. They agreed | `ClickRuleTests`, `ClickRulesVectorTest` |
| L16 (part) | `gherkin/ui/vectors/stepRates.json`: ten scenarios and the two constants for the "about N left" per step. StarCore's `StepRateTracker` (`StepRateVectorTests`) and the desktop's hand copy (`StepRateVectorTest`) are held to them; they agreed. Of the Kotlin copies L16 lists, now pinned: `ProcessingHeadline`, `StepRateTracker`, `WorkingLocation` (the ratio and, since S9, the free space and the byte format), `KeypointDivisor`; `FrameState.isWorking` has no StarCore counterpart | as named |
| E1 (owner's answer) | a click on an undecided group applies the tool's decision in both clients: Keep keeps it, every other tool removes it; a group that has a decision is flipped whatever the tool (the click ignored the tool, so Keep marked an undecided group for removal). `OutlierGroupView.decisionAfterClick(_:tool:)`, `OutlierDecisions.clicked`; `clickRules.json`'s `toggle` cases carry the tool (35). The `tool.help.keep/remove` texts still say "a click switches one group between kept and removed", true of a decided group | `ClickRuleTests`, `ClickRulesVectorTest` |
| L9 (owner's answer, gui) | the gui's horizon refinement waits for a run, as the desktop's does: "Re-run Horizon Refinement" is off while a run is going and "Now" claims nothing (what is pending stays pending for the next run) | `HorizonRefinementWaitsTests` |
| I1 (owner's answer, badges) | the grid cells, filmstrip cells and the grid panel show `FrameProcessingState.badgeText`: the catalogue's text for the state, nothing for a finished frame, as the desktop's badges. `shortString` stays English for the updatable log | `FrameStateBadgeTests` |
| L12 (owner's answer) | the desktop's render dialog starts from the config alone, as the gui's does. An import's own rate and codec are already in the config (`Config.set(videoInfo:)` when the daemon opens a video, sent as `config.video`); the choices are still written to the Mac's preferences, which the gui seeds a new sequence from | `VideoChoiceTest` |
| **L5** | **auto selective frames never reached `.complete`**: `finishAuto(useOutliers: true)` wrote the images and ended at the state it had last set (`.creatingRemovalMask`); `finishSelective` ends with `.complete`, `memoryFreed` and the completion callback, and now so does this branch. That is why the desktop read 0/N complete and the gui's progress line never read N/N. Found with a real run (`RealSequenceRunTests`, daemon, off unless `STAR_REAL_SEQUENCE_DIR` names a folder of full-size frames; run it with `STAR_REAL_SEQUENCE_DIR=/sp/tmp/LRT_07_11_2026-a9-1 STAR_REAL_SEQUENCE_CONFIG=/sp/tmp/star_temp_LRT_07_11_2026-a9-1/config.json swift test --filter RealSequenceRunTests`): six 42 MP frames, six minutes; before the fix all six ended in `creatingRemovalMask` with their finals written, after all six are `complete`. The desktop Gherkin feature `autoSelectiveHorizonTiff16` on the committed 19-frame `test_data/test_a7sii_10` (`STAR_GHERKIN_SEQUENCE=test_data/test_a7sii_10`) now ends `19/19/idle` with no Render All Frames click and passes all seven of its steps (12 minutes against the debug `stard`; its later steps need the validator: `swift build -c release --package-path removal_tools`). The gui's `autoSelectiveHorizonTiff16` as an XCUITest passes too, the first gui UI test run on this branch (`TEST_RUNNER_STAR_GHERKIN_SEQUENCE=test_data/test_a7sii_10 xcodebuild test -project gui/star.xcodeproj -scheme star -configuration Release ENABLE_TESTABILITY=YES -only-testing:starUITests/GeneratedFeatureUITests/testAutoSelectiveHorizonTiff16Feature CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`, 15 minutes) | `FrameFinishAutoSelectiveTests` (StarCore, fails on the old code), `RealSequenceRunTests`, the desktop feature run |
| Q6, L4 (D7, D8) | the desktop's left panel has no Processing and Render blocks (all seven actions are in the Actions menu, which `commands.json` holds both clients to), and "Render All Frames" is Process All with its question about rendering the video, as the gui's `RenderAllFramesButton` (it was a separate pass that finished every frame from what was on disk; the pass and its progress bar are gone). `render.all.frames` is a recorded gap of the desktop (an AWT menu item cannot be tagged). The desktop Gherkin runner no longer clicks it | `LeftPanelTest`, `IdRegistryTest`; the screen looked at in a rendered screenshot |
| Right panel layout | found by looking: the "Effort" choices wrapped "Light" to a letter a line and pushed "Custom…" out of sight (mine, Q5), and the mode label beside its Change Mode button wrapped to a letter a line (older). The choices are stacked as the gui stacks them and the label is over its button | `UiSnapshotTest` renders it (below) |
| UI snapshots | `UiSnapshotTest` (`star-desktop/src/gherkinTest`, off unless `STAR_UI_SNAPSHOT_DIR` is set) renders the real Compose root over a real `stard` and a small synthetic sequence to PNG files, one per screen: `edit grid settings settingsexpert progress prerender customlimits rendervideo` (the start screen cannot: JavaFX). `STAR_UI_SNAPSHOT_DIR=/tmp/shots STAR_UI_SNAPSHOT_MODES=edit,settings ./gradlew gherkinTest -Pstar.stard.path=$PWD/../daemon/.build/debug/stard --tests '*UiSnapshotTest*'`. This is how the desktop's screens can be looked at without computer use | itself |
| S9 | the desktop's byte counts are StarCore's (`humanReadableBytes`: binary units, "1.5GB", no TB) and `gherkin/ui/vectors/byteFormat.json` pins both (`ByteFormattingTests`, `SharedConstantsTest.byteCountsAreFormattedAsStarCoreDoes`); it said "1.4 GB" in decimal units, so one volume read two ways. The free space the dialogs show comes from the daemon: `Session.GetFreeSpace` (additive) answers with `DiskSpaceCheck.availableBytes` (on a Mac the capacity "for important usage", which counts what the system would purge, so the desktop no longer shows a shortage the gui does not); the JVM's `usableSpace` is the fallback when the daemon cannot say or is too old | `MappingTests.testFreeSpaceIsStarCoresCountForTheVolumeHoldingThePath`, `DispatcherTests` (the method is listed), `WorkingLocationFreeSpaceTest`; the dialogs not looked at. The disk-space ratio copy (`WorkingLocation.PEAK_TO_INPUT_RATIO`) stays a copy, pinned by `constants.json` |
| P9 (Limited by) | the governor's verdict (`ResourceGovernor.latest`, which `FrameGraphBuilder` starts for the daemon's runs) rides on the step report: `StepProgress.limited_by` and `resources_sampled` (additive; "not sampled" is not "not limited"). The desktop shows "Limited by: GPU" / "Not limited by a resource" under the control, in the right panel and the modal, with the gui's `ui.use_status_*` keys | `StepProgressReportTests.testTheResourceTheGovernorBlamesIsPassedOn`, `ResourceStatusTest`; the line not looked at |
| P9 (Custom) | `Config.custom_cpu_width/qos/gpu_width/gpu_duty_cycle/disk_streams_per_volume/io_policy` (always sent; applied clamped to the gui popover's ranges; unknown names ignored) and the write-only `start_custom_from_profile`: on the request that changes the profile to custom it applies `makeCustom`, so Custom starts as the profile it leaves (the gui's observer does this; the desktop's Custom started from the last custom values). A flag, not inferred from absent fields, because the settings sheet switches to Custom and edits the pipeline depth in one save. The desktop's Custom chip (modal and right panel) switches with the flag and opens `ResourceCustomLimitsDialog`: pipeline depth, memory, CPU/GPU/disk widths, GPU duty cycle, thread and disk priority, each applied as changed (sliders when let go), with the gui's `ui.use_custom_*` labels | `ExpertConfigFieldsTests` (round trip, clamps, ignored names, the flag with and without), `ResourceProfilesTest` (switch sets the flag only when entering Custom; limits read back; held to the daemon's ranges); the dialog not looked at |
| I1 | gui outlier table headers (`"id"`, `"size"`, `"remove"`, each feature's own name) read the catalogue keys the desktop already used (`ui.name`, `ui.size`, `ui.remove`, `ui.<feature>`, `ui.classification_score`); `gherkin/ui/vectors/outlierColumns.json` lists the always-shown and the 35 optional columns in table order with label keys and defaults, and each client checks its own table against it (they already agreed). The Remove and Keep tool help (`tool.help.remove`, `tool.help.keep`) now says a click switches the group and a dragged box sets it (D2: the gui's click flips the decision whichever tool is chosen), in all 22 tables; only the gui shows tool help | `OutlierColumnsTests`, `OutlierColumnsTest`; the headers themselves not looked at |
| I1 | gui `HighLevelCleanMethod`/`AutoPreservationMode` hover texts and paragraphs were English paragraphs in StarCore. The paragraphs read `ui.mode_desc_automatic`, `ui.mode_desc_selective`, `ui.mode_desc_auto_selective` (what the desktop's (i) panels already showed, so the two now say the same thing); the four short hover texts are new keys `ui.clean_method_tip.automatic/selective` and `ui.selective_auto_clean_tip.yes/no` in 22 tables, and the desktop sheet shows them on hover (`CleanMethodTexts`). `cleanMethod.texts` in `constants.json` lists the keys | `SharedConstantsTests.testTheCleanMethodTextsAreTheDesktopsAndTranslated` (every text is its key's value, in English and German, and German differs), `SharedConstantsTest.theCleanMethodTextsAreTheGuis`; the sheets themselves not looked at |

### 9.2 Looked at, not done, and what the next person needs to know

* **L7 (D6):** "re-process this frame" / "find outliers" still run the graph with the modal on the desktop, where the gui works inline (`findOutliersAndRender`: empty outlier groups, `findOutliers()`, the decision tree, render now). The daemon needs an inline path for it. It can be built and tested now: `RealSequenceRunTests` runs the real pipeline over a few frames of the owner's `a9-1` sequence (see the L5 row), which gives a frame with every prerequisite on disk.
* **L9 (daemon half): closed by the owner's answer.** The gui waits for a run as the desktop does; the daemon keeps refusing a refinement during a run.
* Not started: P5 (live-apply with Dismiss: the gui's sheet applies each edit and has a Dismiss button; the desktop's has Cancel, Save and Process Now; the screens can be looked at now with `UiSnapshotTest`, but there is no picture of the gui's sheet to compare with), P8's layout (two columns, collapsed groups, the expert toggle as a button), M10–M11 (D10, D11: the main window's close and the secondary windows' lifetime; windows cannot be rendered by the snapshot test), D12's removable recents in the gui.
* The desktop shows no tool help at all (`tool.help.*` are read only by the gui); that is a gap of its own, not listed in §4.
* **How to look at the desktop:** `UiSnapshotTest` (see the table). **How to run the real pipeline:** `RealSequenceRunTests` (daemon) and the Gherkin features on `test_data/test_a7sii_10` (`STAR_GHERKIN_SEQUENCE=test_data/test_a7sii_10`; the desktop's needs `swift build -c release --package-path removal_tools` first for its later steps).

### 9.3 Blocked on the owner

* ~~`sudo automationmodetool enable-automationmode-without-authentication`~~ done by the owner on 2026-10-30: `automationmodetool` now says "This device DOES NOT REQUIRE user authentication to enable Automation Mode" (the mode itself is switched on per UI-test run).
* The `ui_small` and `ui_small_selective` fixtures (§6.3) were to be built from `a7sii_10`, which is not in this Mac's test-data cache. The repository carries a 19-frame JPEG sequence of its own, `test_data/test_a7sii_10` (44 MB), which the Gherkin runners take as a plain path (`STAR_GHERKIN_SEQUENCE=test_data/test_a7sii_10`), and the owner's `a9-1` footage (`/sp/tmp/LRT_07_11_2026-a9-1`, with its `star_temp_` folder and star 0.12.6 output) serves the heavy runs. An upload is not needed to start.
* Phases 0–2 (spikes, `gherkin/ui`, the `@ui` corpus, CI) are not started, and are no longer blocked; the Layer 0 pieces that need no app (the gui lint, the command table with its menus,
  the id registry and the shared vectors) are in.
