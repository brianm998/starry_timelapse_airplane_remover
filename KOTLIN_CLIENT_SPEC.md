# Star Kotlin/Compose Client — Implementation Spec

**Status:** Authoritative spec for the cross-platform GUI client.
**Reads with:** `CROSS_PLATFORM_DAEMON_DESIGN.md` (the daemon `stard` + the wire protocol/method contract).
This document specifies the **client** side: how it bridges to StarCore through `stard`, how it reproduces the
macOS SwiftUI GUI 1:1, and how it stays byte-compatible with the Swift client's sessions.
**Audience:** the agent implementing the Kotlin/Compose desktop app. A separate agent has `stard` nearly done
to the design-doc contract.

---

## 0. The four requirements, and how this spec meets each

1. **Bridge into StarCore via stard.** The client never links StarCore. It spawns `stard` and drives it over
   the stdio protobuf protocol (§2). Every StarCore capability is reached through a `stard` method (§3).
2. **UI 1:1 with the Swift client (~99% on desktop).** §5 maps every macOS view to a Compose composable and
   names the Swift source file that is the pixel-level source of truth for it.
3. **Functional match, including ffmpeg decode/encode.** All processing, video import, and video export run
   inside `stard` (= StarCore = the same ffmpeg path the Swift app uses). The client supplies UI and choices
   (§4, §6).
4. **Same temp structure + config format; cross-client resume; identical output.** Guaranteed structurally by
   the cardinal rule below — not by reimplementing formats.

### Cardinal rule (read this first)

> **The Kotlin client contains ZERO StarCore-format serialization and ZERO pixel processing.**
> `config.json`, the temp/working-file tree, outlier `.bin` files, previews, rendered output frames, and
> ffmpeg decode/encode are **all** produced by `stard` (i.e., by StarCore). The client only: (a) drives `stard`
> over RPC, (b) **reads** image files by the paths `stard` returns, and (c) stores its own *client-local* UI
> preferences in its own location.

Everything in requirement #4 follows from this rule for free:
- **Config compatibility** — `config.json` is written by StarCore's `ConfigManager` inside `stard`, identical
  bytes to the Swift app. The client edits config only via `Sequence.UpdateConfig`.
- **Temp-structure compatibility** — the working tree is created by StarCore inside `stard`; the client never
  computes a StarCore path or writes a working file.
- **Cross-client resume** — opening the other client's session is just `Session.OpenConfig` pointed at its
  existing `config.json`; StarCore's own completion-detection/resume logic runs in `stard`, identical to the
  Swift app.
- **Identical output** — the client performs no processing, so it *cannot* introduce divergence. Output
  identity is bounded only by StarCore's own determinism, which is the same code for both clients (see §4.4,
  including the same-StarCore-version caveat).

If you ever feel tempted to parse `config.json`, write a `.bin`, or compute an output path in Kotlin — stop.
Add or use a `stard` method instead.

---

## 1. Project structure (Gradle, Compose Multiplatform desktop/JVM)

```
star-desktop/
  build.gradle.kts                 # Compose Multiplatform (desktop) + protobuf-kotlin (NO grpc plugin)
  proto/                           # SAME .proto as daemon/ — single source of truth (submodule/symlink/CI copy)
  src/jvmMain/kotlin/com/star/
    proto/                         # generated protobuf-kotlin/-java message types
    engine/
      DaemonProcess.kt             # spawn/own/supervise the stard child process
      StdioConnection.kt           # framing + reader loop + serialized writer + id registries (§2)
      StarClient.kt                # typed suspend/Flow API over every §3 method
      EngineState.kt               # connection status, restart, error surfacing
    data/
      SessionRepository.kt         # open video/sequence/config; config get/update; StateFlow<SessionState>
      ProcessingRepository.kt      # Start/Cancel; collects StreamProgress into per-frame state
      OutlierRepository.kt         # list groups; set decisions; label-image + preview cache
      FrameRepository.kt           # preview/label paths; per-frame clean method
      ExportRepository.kt          # render sequence / export video
      ImageCache.kt                # load PNG/TIFF files (by path) into Compose ImageBitmap
      LocalPreferences.kt          # client-local prefs (recent files, window, UI) — see §4.5
    ui/                            # Compose — mirrors gui/ 1:1 (§5)
    ...
  src/jvmMain/composeResources/    # icons/assets reproduced from gui/ asset catalog
```

- **No gRPC, no swift/NIO concerns** — JVM `Process` stdio is binary-clean on all OSes; the Windows binary-mode
  concern is entirely on the Swift side.
- Compose Multiplatform desktop targets the JVM; package per-OS with jpackage / `nativeDistributions`, bundling
  the matching `stard` binary (and ffmpeg, per `stard`'s needs).

---

## 2. Bridging to StarCore through stard (transport)

This is the client side of `CROSS_PLATFORM_DAEMON_DESIGN.md` §4–§5. Implement it exactly.

### 2.1 Process lifecycle (`DaemonProcess`)
- Resolve the bundled `stard` binary next to the app; spawn `stard --scratch <dir> [--log-file <path>]`.
- Own its three streams: **stdin** (client→daemon frames), **stdout** (daemon→client frames), **stderr**
  (daemon logs → drain to the app log; never parse as protocol).
- No port, no handshake, no token — the parent owns the pipes. The first frame sent is `Daemon.Hello`.
- **Shutdown:** send `Daemon.Shutdown`, then close stdin; closing stdin gives the daemon EOF as a backstop.
- **Crash:** stdout EOF / process exit ⇒ set engine state to "stopped," offer restart; on restart, re-open the
  last session via `Session.OpenConfig` (sessions are reconstructible from on-disk `config.json`).

### 2.2 Framing & envelope (`StdioConnection`)
- Wire = **4-byte big-endian length** + serialized `star.v1.Envelope` (fields & `Kind` enum per design §5.2).
- A single **reader coroutine** loops on stdout: read length, read body, parse `Envelope`, dispatch by `id`.
- A single **writer coroutine** drains an outbound `Channel<ByteArray>` to stdin (serialized writer — no other
  code writes stdin). `id` is an `AtomicLong`.
- Registries: `ConcurrentHashMap<Long, CompletableDeferred<Envelope>>` for unary, and
  `ConcurrentHashMap<Long, SendChannel<Envelope>>` for streams. Terminal frames (`RESPONSE`/`ERROR`/
  `STREAM_END`) complete/close and remove the entry.

### 2.3 Typed API (`StarClient`)
```kotlin
class StarClient(private val conn: StdioConnection) {
    suspend fun <Req: Message, Resp: Message> call(
        method: String, req: Req, respParser: Parser<Resp>
    ): Resp                                  // REQUEST -> RESPONSE | ERROR(throws StarRpcException)

    fun <Req: Message, Item: Message> serverStream(
        method: String, req: Req, itemParser: Parser<Item>
    ): Flow<Item>                            // REQUEST -> STREAM_ITEM* -> STREAM_END; cancel() sends CANCEL{id}
}
```
- `ERROR` envelopes throw `StarRpcException(code, message)` from `call`, or terminate the `Flow` exceptionally.
- Cancelling the `Flow`'s coroutine scope sends a transport `CANCEL{id}` (distinct from `Processing.Cancel`,
  which cancels the *job*).
- All calls are `suspend`/`Flow`; UI uses them from `viewModelScope` on `Dispatchers.Default`/`IO`.

---

## 3. stard method → client mapping

Each design-doc §7 method gets one typed wrapper. Repositories call these; never construct envelopes in UI.

| `stard` method | Shape | `StarClient`/Repository call | Backed Swift-app behavior |
|---|---|---|---|
| `Daemon.Hello` | unary | engine handshake; learn `scratch_dir`, version | app launch |
| `Daemon.Shutdown` | unary | on app exit | quit |
| `Session.OpenVideo` | stream | `SessionRepository.openVideo(path, cfg)` → decode progress + `SessionInfo` | import video (ffmpeg decode in stard) |
| `Session.OpenSequence` | unary | `openSequence(dir, cfg)` | open image sequence |
| `Session.OpenConfig` | unary | `openConfig(configJsonPath)` | **open existing session (resume / cross-client)** |
| `Session.Close` / `Session.List` | unary | session lifecycle | close / list |
| `Sequence.GetConfig` / `Sequence.UpdateConfig` | unary | read/persist `Config` | all settings edits |
| `Frame.Get` | unary | `FrameRepository.info(idx)` | per-frame status |
| `Frame.GetPreview` | unary | `previewPath(idx, viewMode)` → `ImageRef` | frame display (original/processed/subtraction/validation) |
| `Frame.GetOutlierLabelImage` | unary | `labelImagePath(idx)` → `ImageRef` | outlier overlay hit-testing source |
| `Frame.SetCleanMethod` | unary | per-frame clean-method override | clean-method picker |
| `Outlier.List` | unary | `OutlierRepository.groups(idx)` → metadata | outlier boxes + table |
| `Outlier.SetDecisions` | unary | keep/remove (optionally `rerender`) | click-to-keep/remove, Keep/Remove/Clear-all |
| `Outlier.RenderFrame` | unary | paint frame with current decisions → `ImageRef` | render current frame |
| `Processing.Start` | unary | begin detection (range) | Process all / remaining frames |
| `Processing.StreamProgress` | stream | per-frame state events → grid/filmstrip status | progress bars + state grid |
| `Processing.Cancel` | unary | stop the job | cancel processing |
| `Export.RenderSequence` | stream | render final frames + progress | render all frames |
| `Export.Video` | stream | encode video + progress (ffmpeg in stard) | Render Video dialog |

**`stard`/proto support for video (now specified in the design doc — use these):**
- `ExportVideoRequest` carries `VideoEncodeSettings` (frame_rate + codec/encoder/pixel_format/muxer as
  FFmpeg* **rawValue strings**), matching the Swift `RenderVideoSheetView` exactly. The five settings are also
  persisted on `Config.video` (the Swift app stores them in config and the dialog edits them).
- `Session.OpenVideo`'s terminal `SessionInfo.source_video_info` (`VideoInfo`) surfaces the decoded source's
  settings so the client defaults an export to re-encode matching the source.
- `Export.GetVideoCapabilities` returns the `VideoCapabilities` graph (frame rates; per-codec encoders;
  per-encoder pixel formats + muxers) so the Render Video dialog's **cascading pickers** behave like the Swift
  app's (`codec.encoders` → `encoder.pixelFormats` / `encoder.supportedMuxers`). Fetch once and cache.

---

## 4. Cross-client interoperability & identical output (requirement #4 in detail)

### 4.1 Opening the other client's session
A session is fully described by its on-disk `config.json` (it records `outputPath`, `tempOutputPath`,
`imageSequencePath`, neighbor counts, per-frame overrides, etc.). To continue any session — whether started by
the Swift app or a prior Kotlin run — the client calls `Session.OpenConfig(configJsonPath)`. `stard` (StarCore)
loads it, resolves all paths, and detects which frames are already complete and which can resume. The client
does nothing format-specific; it just renders the state `stard` reports.

### 4.2 Where the shared files live (informational — DO NOT reimplement)
This is StarCore's domain via `stard`. Listed only so you recognize the artifacts you may *read*:
- `config.json` — the session config (Codable `Config`; pretty-printed JSON, `withoutEscapingSlashes`; carries
  `starVersion`). **Written/read only through `stard`.**
- Temp working tree (under StarCore's `tempOutputPath`): keypoints, aligned/subtracted frames, per-frame
  `outliers/<frameIndex>/` (outlier `.bin` little-endian blobs + `OutlierGroupPaintData.json`), horizon masks,
  previews, thumbnails.
- Final output frames (under StarCore's output dir, e.g. `<sequence>-star-v-<version>/`) at the source bit
  depth and file extension recorded in the config.

The client reads only the **paths returned by RPCs** (`ImageRef.path` for previews/label images). It must not
assume or compute any of these paths itself; StarCore may change them.

### 4.3 Edits persist in the shared format automatically
Keep/remove decisions go through `Outlier.SetDecisions`, which `stard` persists via StarCore (the same
`OutlierGroupPaintData.json` the Swift app writes). Settings edits go through `Sequence.UpdateConfig` →
StarCore writes `config.json`. So a half-reviewed, half-rendered session handed between clients carries its
decisions and progress with it.

### 4.4 Why output is identical (and the one caveat)
The client renders no pixels and chooses no encoding parameters — `stard`/StarCore does. Therefore a sequence
rendered partly under a Kotlin-driven `stard` and partly under the Swift app is produced by the *same StarCore
code from the same config and the same persisted outlier decisions*, frame for frame. The client cannot cause
divergence.
- **Caveat — version alignment:** identity holds only when `stard` and the Swift `gui` link the **same StarCore
  version** (algorithms/output can change between versions; `config.starVersion` records it). Treat
  "matching StarCore version across clients" as a release requirement, and surface a warning if a session's
  `starVersion` differs from the running engine.
- Any run-to-run nondeterminism (if any exists in StarCore) is a property of StarCore shared by both clients,
  not introduced here. The guarantee is precisely: *same engine + same inputs + same decisions ⇒ same output.*

### 4.5 Client-local preferences (the ONE thing the client persists itself)
UI/session-list state is not a StarCore artifact. The Swift app stores it in `~/.star.userprefs.json`
(`UserPreferences.swift`: `recentlyOpenedSequencelist` = `{path: epochSeconds}`, plus UI prefs).
- **Recommended:** read/write the **same** `~/.star.userprefs.json` schema so recent-files and preferences are
  shared between the Swift and Kotlin apps on the same machine (nice parity; small file). `LocalPreferences.kt`
  owns this — and it is the *only* file the client serializes.
- This file is explicitly **not** required for session interop (that's `config.json` via `stard`); it's a
  quality-of-life parity item. If you diverge, keep it additive and never let it collide with the Swift schema.

---

## 5. UI parity spec (1:1 with the macOS GUI)

**Source of truth:** the macOS `gui/star/*.swift` views. For each composable below, the named Swift file is the
authoritative reference for layout, labels, colors, sizes, and behavior — **read it** and match it. This spec
gives the structure and the cross-cutting rules; the Swift file gives the pixels.

### 5.1 App shell & windows
| Compose | Swift source | Notes |
|---|---|---|
| `StarApp` (application + Window) | `StarApp.swift`, `AppDelegate.swift` | single main window; reproduce window default size; app lifecycle (the Swift app disables App Nap — N/A on JVM) |
| Menu bar | `StarCommands.swift` | reproduce every menu + command + its shortcut (§5.7) |
| Root content & mode switch | `ContentView.swift`, `ViewModel.swift` | three interaction modes: **Edit / Scrub / Grid** (shortcuts E/S/G) |
| Separate Outlier window | `OutlierWindowView.swift`, `OutlierWindowViewModel.swift` | secondary window (Cmd+Opt+X family) — reproduce as a second Compose window |
| Separate Alignment window | `AlignmentWindowView.swift` | secondary window |

### 5.2 Open / startup flow
| Compose | Swift source |
|---|---|
| Startup / initial screen | `StartupView.swift`, `InitialView.swift` |
| Drag-and-drop target | `FinderStyleDropZone.swift` |
| Recent files list | `InitialView.swift` + `UserPreferences.swift` (`recentlyOpenedSequencelist`) |
| Loading state | `ImageSequenceLoadingView.swift` |

Open actions map to: video file → `Session.OpenVideo`; sequence dir → `Session.OpenSequence`; `config.json` →
`Session.OpenConfig`. Use the platform file chooser (Compose `FileDialog`/AWT) in place of `NSOpenPanel`.

### 5.3 Main editing view (Edit mode)
The core 3-region layout: **left panel · center frame view · right panel**, plus **bottom controls** and a
**filmstrip**. Panels are collapsible (`ExpandUpButton`/`ExpandDownButton`).

| Compose | Swift source | Contents |
|---|---|---|
| Main container | `ImageSequenceView.swift`, `ImageSequenceViewModel.swift` | owns the active-frame, selection, processing state |
| Frame display | `FrameView.swift`, `FrameEditView.swift`, `FrameImageView.swift`, `FrameEditImageView.swift`, `FrameViewModel.swift` | shows the current frame's preview image (from `Frame.GetPreview`) |
| Zoom/pan | `Zoomable/*` (`ZoomableView`, `NSScrollViewZoomableModifier`) | scroll/pinch to zoom, drag to pan, fit-to-window, min/max zoom — reproduce in Compose (`graphicsLayer` scale/translate + gesture handling) |
| Outlier overlay | `OutlierGroupView.swift`, `OutlierGroupViewModel.swift` | colored boxes + direction arrows over outlier groups (§5.5) |
| Outlier table | `OutlierGroupTable.swift` | tabular list of groups for the frame |
| Horizon painter | `HorizonPainterView.swift`, `HorizonPaintState.swift` | brush UI to paint a reference horizon |
| Custom cursor | `CursorView.swift` | tool-dependent cursor feedback |
| Left panel | `LeftPanel.swift`, `BottomLeftView.swift` | processing controls + progress + stats + operation queue |
| Right panel | `RightPanel.swift`, `BottomRightView.swift` | tool picker + sliders + per-frame settings |
| Progress | `ProgressBars.swift`, `CircularProgressView.swift`, `BlobProcessingView.swift` | driven by `Processing.StreamProgress` |

**Action buttons** (left/right panels & toolbar) — reproduce each, wired to the mapped RPC:
| Compose button | Swift source | RPC |
|---|---|---|
| Process all frames | `ProcessAllFramesButton.swift` | `Processing.Start` (full range) |
| Process remaining | `ProcessRemainingFramesButton.swift` | `Processing.Start` (resume) |
| Find outliers on current frame | `FindOutliersOnCurrentFrameButton.swift` | `Processing.Start` (single) |
| Reprocess current frame | `ReProcessCurrentFrameButton.swift` | `Processing.Start` (single, force) |
| Apply decision tree (current) | `ApplyDecisionTreeButton.swift` | re-runs classifier → `Outlier.SetDecisions` |
| Apply decision tree (all) | `ApplyAllDecisionTreeButton.swift` | bulk classify |
| Keep all / Remove all / Clear undecided | `KeepAllButton.swift`, `RemoveAllButton.swift`, `ClearUndecidedButton.swift` | bulk `Outlier.SetDecisions` |
| Render current / all frames | `RenderCurrentFrameButton.swift`, `RenderAllFramesButton.swift` | `Outlier.RenderFrame` / `Export.RenderSequence` |
| Change tool | `ChangeToolButton.swift` | local tool state |
| Expand/collapse panels | `ExpandUpButton.swift`, `ExpandDownButton.swift` | local layout state |

### 5.4 Grid mode (Lightroom-style)
| Compose | Swift source |
|---|---|
| Thumbnail grid | `GridView.swift` (uses `Frame.GetPreview`/thumbnails) |
| Grid left/right panels | `GridLeftPanel.swift`, `GridRightPanel.swift` |
Reproduce selection states and per-thumbnail status indicators.

### 5.5 Outlier overlay rendering & interaction (the heart of the editing UX)
Reproduce `OutlierGroupView.swift` exactly:
- Per frame, fetch group metadata via `Outlier.List` (id, bounds, `should_remove`, score, line) and the
  **label image** via `Frame.GetOutlierLabelImage` (16-bit, pixel = group id).
- **State colors — confirmed from `OutlierGroupViewModel.swift` (`groupColor`/`arrowColor`). Match exactly:**
  - *Group box* (`groupColor`): selected → **orange**; will-remove → **red**; will-keep → **green**;
    undecided (`should_remove` unset) → **blue**.
  - *Edge arrows* (`arrowColor`): selected → blue; decided **and** arrow-hovered → red (remove) / green (keep);
    decided and not hovered → white; undecided and arrow-hovered → red; undecided and idle → blue.
  - Use SwiftUI's standard named colors (`.red/.green/.orange/.blue/.white`) as the reference hues. Box fill
    opacity is `0.5` normally and `1/8` when selected/arrow-selected; there is a white border at ~`0.33`
    opacity. (Reproduce from `OutlierGroupView.swift` lines ~190–232.)
  - **Direction arrows:** when a group is selected/hovered/decided/undecided-pending, four arrows point inward
    toward it from the frame edges (`arrow.right/down/left/up`), with connecting guide lines when selected.
    These are SF Symbols — substitute bundled equivalents (§5.9).
- **Hit-testing without round-trips:** load the label image once per frame, build a pixel→group-id lookup, and
  resolve clicks locally. Toggling a group updates local tint immediately and sends `Outlier.SetDecisions`
  (with `rerender:false` for fast toggles; request a repaint via `rerender:true`/`Outlier.RenderFrame` only
  when the user wants the painted result). The Swift toggle sets `RemoveReason.userSelected(!willPaint)` —
  i.e. clicking flips the current decision; mirror this.
- **Tools — confirmed `ToolType` (`ImageSequenceViewModel.swift`); 8 in `allCases`, mapped to shortcuts 1–8 in
  this order**, each with a custom PNG icon asset (re-export from the gui asset catalog into
  `composeResources/`):
  1. `remove` — "Remove" — `remove_icon`
  2. `keep` — "Keep" — `keep_icon`
  3. `razor` — "Razor" — `razor_icon`
  4. `shovel` — "Shovel" — `shovel_icon`
  5. `trash` — "Trash" — `add_to_trash_icon`
  6. `removeFromTrash` — `remove_from_trash_icon`
  7. `multi` — `multi_choice_icon`
  8. `information` — `info_icon`

  (Plus a non-listed `none`.) Reproduce each tool's selection/paint behavior from `ChangeToolButton.swift` +
  `RightPanel.swift` + `OutlierGroupView.swift`.

### 5.6 Bottom controls, filmstrip, scrubber, playback
| Compose | Swift source |
|---|---|
| Bottom control bar | `BottomControls.swift` |
| Filmstrip | `FilmstripView.swift`, `FilmstripImageView.swift` |
| Scrub slider | `ScrubSliderView.swift` |
| Playback transport | `VideoPlaybackButtons.swift` |
| Editable frame number | `EditableFrameNumberView.swift`, `EditableNumberView.swift` |

**Playback is a client-side timed slideshow** of preview frames at a chosen framerate (with prefetch) — it is
**not** ffmpeg and not a video stream. Reproduce the Swift app's playback loop, fast-skip strategies (skip
empty frames, jump to next outlier type), and prefetch.

### 5.7 Dialogs / sheets
| Compose | Swift source | Purpose |
|---|---|---|
| Processing settings | `ProcessingSettingsView.swift` | every detection/processing option → `Config` fields (`Sequence.UpdateConfig`) |
| Render video | `RenderVideoSheetView.swift` | codec/framerate/pixfmt/etc. → `Export.Video` |
| Pre/Post render prompts | `PreProcessingRenderPromptView.swift`, `PostProcessingRenderPromptView.swift` | confirmation flows |
| Preferences | `UserPreferences.swift`-backed sheet | client-local prefs (§4.5) |
| Info dialog | `InfoDialogView.swift` | informational |
| Multi-choice / multi-select sheets | `MultiChoiceSheetView.swift`, `MultiSelectSheetView.swift` | batch operations |
| New-release sheet | `NewReleaseSheetView.swift` | update notice (optional) |

### 5.8 Keyboard shortcuts
Reproduce **every** shortcut from `StarCommands.swift` and the per-view `.keyboardShortcut` modifiers. Known
set to verify against source (treat the Swift source as authoritative if any differ):
- Bulk outlier ops: **A** keep-all, **K** remove(kill)-all, **U** clear-undecided (confirm letters in source).
- Tools: **1–8**.
- Modes: **E** edit, **S** scrub, **G** grid.
- Frame navigation: **arrow keys** (next/prev frame, with fast-skip variants).
- Windows: **Cmd+Opt+X** (outlier/alignment windows family).
- Reproduce playback, zoom, and render shortcuts as defined.
Map Compose key handling (`onPreviewKeyEvent`) and use Ctrl on Windows/Linux where macOS uses Cmd.

### 5.9 Visual styling
Match the macOS app's **dark theme** (the agent reported exact RGB values in `OutlierGroupView.swift` and the
panel views — pull them from source). Reproduce: fonts/sizes, spacing, button styles (`SystemButton.swift`,
`ShrinkingButton.swift`), pickers (`StarPicker.swift`, `LimitedSelectionPicker.swift`), and the custom
tool/asset icons from the gui asset catalog (re-export the PNGs into `composeResources/`; SF Symbols used in
the Swift app must be replaced with equivalent bundled icons since SF Symbols are macOS-only).

---

## 6. State model mapping (Swift ViewModels → Compose state)

Mirror the Swift architecture so behavior matches and the code is reviewable side-by-side. All of these become
Compose `ViewModel`s / state holders exposing `StateFlow`, fed by the repositories (§1) which call `stard`.

| Swift (`@Observable`/ObservableObject) | Compose holder | Holds |
|---|---|---|
| `ViewModel.swift` | `AppViewModel` | root app state, interaction mode (edit/scrub/grid), active window |
| `ImageSequenceViewModel.swift` | `SequenceViewModel` | the open session: frame count, per-frame state, current frame, selection, per-frame overrides, processing/sequence state |
| `FrameViewModel.swift` | `FrameViewModel` | one frame: preview/label image refs, outlier groups, clean method, status |
| `OutlierGroupViewModel.swift` | `OutlierGroupState` | one group: bounds, decision, score, line, selection/tint |
| `OutlierWindowViewModel.swift` | `OutlierWindowViewModel` | secondary outlier window state |
| `UserPreferences.swift` | `LocalPreferences` (§4.5) | recent files + UI prefs (the only client-serialized file) |

Per-frame processing status comes from a single `Processing.StreamProgress` `Flow` folded into
`SequenceViewModel` (events: frame_state, frame_saving_state, frame_existing, outliers_loaded, io_progress,
sequence_state) — this drives the progress bars, the filmstrip/grid status badges, and the per-frame state grid.

---

## 7. Functional parity checklist (where each lives)

| Capability | Client (Kotlin) | Daemon (`stard` = StarCore) |
|---|---|---|
| Window/layout/controls/shortcuts | ✅ all UI | — |
| Zoom/pan, overlay tinting, hit-testing, playback slideshow | ✅ local | — |
| Recent files / UI prefs | ✅ `~/.star.userprefs.json` | — |
| Open video (decode) | UI + choices | ✅ ffmpeg decode via `VideoConvert` |
| Open sequence / open config (resume) | UI | ✅ StarCore path resolution + completion/resume |
| Detection / classification / alignment / horizon / blob processing | request only | ✅ all StarCore processing |
| Outlier keep/remove + persistence | UI + clicks | ✅ persists `OutlierGroupPaintData.json` |
| Per-frame & global config edits | UI | ✅ writes `config.json` |
| Render frames / render sequence | UI + trigger | ✅ paints & writes output frames |
| Export video (encode) | UI + codec/fps choices | ✅ ffmpeg encode via `VideoConvert` |
| Horizon reference painting | UI brush → mask data | ✅ stores/uses horizon reference |

If a capability seems to need StarCore logic in the client, it belongs in `stard` — add a method (coordinate
with the daemon implementer) rather than reimplementing in Kotlin.

---

## 8. Testing & verification

1. **Transport unit tests** — framing round-trip; interleaved unary + stream on one pipe; `CANCEL`; stdout EOF
   handling (mirror the daemon's `StdioEcho`-based tests).
2. **RPC integration** — against a real `stard` (CI on Linux **and** Windows): `Hello`, open sequence/config,
   stream progress, set decisions, render.
3. **Cross-client interop test (the requirement-#4 gate):**
   - (a) Process+edit the first half of a fixture sequence with the **Swift app** (or Swift-app-equivalent
     in-process StarCore); (b) `Session.OpenConfig` that session in the **Kotlin client**, finish the second
     half + render; (c) assert the output frames are identical to a sequence processed end-to-end by a single
     client. Run the swap in both directions.
   - Assert `config.json` written by the Kotlin-driven `stard` is byte-identical (modulo legitimately changed
     fields) to the Swift app's, since both go through StarCore.
4. **Golden output** — Kotlin-client-driven render vs `cli/` render of the same fixture ⇒ identical frames.
5. **UI parity review** — side-by-side screenshots of each screen vs the macOS app; diff against the named
   `gui/star/*.swift` source.
6. **Version-mismatch warning** — open a session whose `config.starVersion` ≠ engine version; assert the client
   surfaces the §4.4 warning.

---

## 9. Phased implementation

- **Phase 0 — Engine bridge.** `DaemonProcess` + `StdioConnection` + `StarClient`; `Daemon.Hello` round-trip;
  transport tests. (Depends on `stard` Phase 1.)
- **Phase 1 — Open + view.** Open sequence/config; `Frame.GetPreview`; frame display + zoom/pan + filmstrip +
  scrubber + playback. Recent-files/prefs interop (`~/.star.userprefs.json`).
- **Phase 2 — Process + monitor.** `Processing.Start` + `StreamProgress`; left/right panels, progress bars,
  per-frame state grid; process-all/remaining/current buttons.
- **Phase 3 — Interactive editing.** `Outlier.List` + label image overlay + hit-testing + keep/remove + tools +
  bulk ops + per-frame clean method + `Outlier.RenderFrame`. Grid mode.
- **Phase 4 — Video in/out.** Open video (decode) + Render Video sheet (`Export.Video`) with full codec/fps UI.
  Run the **cross-client interop test** (§8.3).
- **Phase 5 — Parity polish.** Dialogs, menus, all shortcuts, exact colors/icons, secondary windows, horizon
  painter. Side-by-side UI review.

---

## 10. Open questions
1. Secondary windows (Outlier, Alignment) as separate Compose `Window`s vs. docked panels — match the macOS
   multi-window behavior unless it's awkward on Windows/Linux.
2. ~~Exact outlier state colors and tool semantics~~ **RESOLVED** — colors confirmed from
   `OutlierGroupViewModel.swift` (`groupColor`/`arrowColor`) and the 8 tools from `ToolType` in
   `ImageSequenceViewModel.swift`; both now specified in §5.5. Remaining: confirm exact box opacities/border
   from `OutlierGroupView.swift` during implementation (values noted in §5.5).
3. Should `Export.Video` expose the Swift app's advanced ffmpeg settings, or just the common ones first?
   The proto now carries the full `VideoEncodeSettings` (codec/encoder/pixel_format/muxer/frame_rate); the
   open choice is only how much of the cascading-picker UI to build first. Recommend: full
   `VideoCapabilities`-driven pickers in Phase 4 (it's the same data either way).
4. `~/.star.userprefs.json` sharing — confirm we want true shared recent-files between Swift and Kotlin apps
   (recommended) vs. a separate client store.
