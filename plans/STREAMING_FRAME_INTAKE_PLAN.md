# Streaming frame intake: processing a video while its frames are still being extracted

Status: plan, not started.  Written 2026-10-27 against `develop` at b481650d.

This is a plan for an implementing agent.  It says what to build, where it goes, what the
existing code does today (with file references, checked at b481650d), and which traps are
already known.  Where it gives a design choice, the choice is a recommendation, except
where the user has decided it (listed in section 12).  Ask before deviating from the
user-visible behaviour in section 1, which is what the user asked for, or from section 12.

---

## 1. What the user asked for

1. **A frame-access interface in StarCore.**  Every client gets an original frame for an
   index through one interface.
   - For an **image sequence** (a folder of files) every frame is available at once, with no
     added delay.
   - For a **video**, a background process extracts frames, starting at the first frame.
     Asking for a frame that has not been extracted yet waits until it has been.
   - When the video allows cheap direct access to any frame (ProRes and other intra-only
     formats), the extractor still starts at the beginning and goes in order, but can be
     asked to **jump ahead** and extract one or more later frames first.
2. **Visibility of availability.**  Other parts of the program (the GUIs above all) can see
   which frames exist.  For a frame that is not there yet, there are two calls:
   - a **waiting** one that returns, or calls back, when the frame becomes available;
   - a **non-waiting** one that returns nil or false straight away if the frame is not
     there right now.
3. **A checkbox on the video import dialog: "Extract video in background".**
   - On by default for ProRes and other direct-access formats; off by default for H.264,
     H.265 and other long-GOP formats.
   - When it is on, both the macOS (SwiftUI) GUI and the Kotlin desktop GUI go straight to the
     main sequence screen while the video is still being decoded.
   - Its help text explains why extracting H.264 and similar videos in the background can
     make the user wait if they define horizons by hand.
4. **Frames that are not extracted yet are marked as such** in the GUI, in the filmstrip and
   in the edit and scrub views.
5. **Extraction follows the user.**  When the user moves to another part of the video, the
   frames around where they are get extracted first, when the video's format allows it.
6. **A wait indicator.**  A user waiting on a frame sees how long it will probably take to
   be extracted, with a progress indicator.
7. **Overall extraction progress.**  While a video is being extracted, the GUI shows a
   progress bar and "N of M frames".
8. **TIFF compression is chosen at import** (added with the answers in section 12): an
   uncompressed or compressed option, presented with the TIFF/JPEG question, with a
   description of the trade-off.

The CLI is a client too.  It has no GUI, but it should get the same pipeline overlap
(section 8).

---

## 2. How it works today

### 2.1 The decode

`decodeVideo(named:format:progress:)` in `StarCore/Sources/StarCore/VideoConvert.swift:38`
is the only way in, and it is all-or-nothing:

- It makes `<video dir>/<sanitized video name>/` and runs **one** ffmpeg process,
  `ffmpeg [hw decode args] -i <video> <FrameDecodeFormat args> <dir>/image_%04d.<ext>`
  (`FrameDecodeFormat.ffmpegOutputArguments`, `FrameDecodeFormat.swift`).  ffmpeg's image2
  muxer numbers files from **1**, so frame index 0 is `image_0001`.
- Progress comes from parsing `frame=  123` out of ffmpeg's stderr (`FFmpegRun`, same file).
- The frame count is read the cheapest way that works (`videoFrameCount`: the header, then
  `-count_packets`, then `-count_frames`).  A header count **can be an estimate**
  (from duration × rate), which is why the progress callback clamps `total` to at least
  `current`.
- Probes for frame rate, codec, pixel format and audio run beside it; the audio sidecar is
  extracted before the call waits for ffmpeg.
- It returns only once ffmpeg has exited: `(outputDirectory, VideoInfo)`.
- Cancelling it terminates ffmpeg and removes the folder if this call made it.

Callers, all of which wait for the whole decode before doing anything else:

| Client | Call site | Then |
|---|---|---|
| macOS gui | `ViewModel.startup(withVideoToProcess:format:)`, `gui/star/ViewModel.swift:599` | `startup(withNewImageSequence:)` on the folder |
| daemon (Kotlin client) | `Session.openVideo`, `daemon/Sources/stard/Session.swift:1050` | builds an `ImageSequence` on the folder |
| cli | `StarCli.swift:426` | processes the folder like any sequence |

### 2.2 How originals are found and read

- `ImageSequence` (`StarCore/Sources/StarCore/ImageSequence.swift`) **lists the directory
  once, at init**, and keeps the sorted list as `filenames`.  Everything takes the frame
  count from `filenames.count`, and `frameIndexToBaseNameMap` is built from it in three
  places (`Session.buildFrameGraph`, `ImageSequenceViewModel.setup`, cli `Processor`).  A
  half-extracted folder therefore looks like a shorter sequence.  This is the first thing
  that has to change.
- `ImageSequence.getImageInfo()` decodes `filenames[0]` to learn the frame size.
- `ImageAccessor.loadInt` (`ImageAccessor.swift:248`) returns **nil** for an original
  that is not on disk ("original does not exist, nothing to return").  For a preview or a
  thumbnail it falls back to making one from the original.
- The C++ merge reads neighbours **by filename** through
  `StarCppBridge.ImageCache.setLoader` → `DecodedFrameStore.shared.load` (registered in
  `ImageCache.init`, `ImageCache.swift`).  That read is synchronous, on a native thread.
- `FrameAlignmentProcessor` (lines 187, 236) and `FrameHorizonProcessor` (468, 662, 861)
  index `imageSequence.filenames` directly.
- Previews and thumbnails of originals are written by
  `ImageAccessor.writeMissingImages(_:)` (`ImageAccessor.swift:800`), over **all** frames in
  `farthestFirstOrder`, and only if the first and last frame are missing theirs.  The
  daemon also has `daemon/Sources/stard/PreviewPrewarm.swift`.

### 2.3 What the pipeline waits on

The frame graph (`FrameGraphBuilder.build`, `FrameGraphBuilder.swift:544`) is
`AsyncOperation`s on an `OperationQueue` with dependencies.  The order of stages matters a
lot here, because it decides how much streaming can overlap:

1. Horizon detection per frame (no dependencies), or one **temporal static horizon** that
   samples **48 frames evenly across the whole sequence**
   (`TemporalHorizonDetector.defaultSampleCount`).
2. Merged horizon: per frame on a moving tripod (from a neighbourhood of horizon ops);
   **one op for the whole sequence** on a static tripod, depending on *every* horizon op.
3. Sky/earth keypoints per frame, **each depending on the merged horizon**
   (`FrameGraphBuilder.swift:~995`).
4. Homographies per frame, depending on its own and its neighbours' keypoints.
5. **`AlignmentValidationOp` depends on every homography op** (`~1182`).
6. Horizon consensus (moving), outliers and merges all depend on validation.

What this means for streaming:

- **Nothing after alignment validation can start before the last frame is extracted**,
  whatever the format.  Streaming overlaps extraction with stages 1–4 (horizons, keypoints,
  homographies) and with preview/thumbnail generation, not with outliers or merges.  Do not
  try to change this in this project.  Validation is global by design (see
  `moving-alignment-gapfill-damage`, `homography-reciprocity-check` in memory).
- **On a static tripod with the automatic horizon, every keypoint op waits on the
  48-frame temporal horizon.**  In in-order extraction, the last of those 48 samples
  arrives just before the end of the video, so **a static automatic-horizon run on H.264
  gains almost nothing** from extracting in the background.  With a direct-access video the
  extractor must fetch those 48 sample frames first (section 4.6).  Then the whole of stages
  1–4 overlaps.
- A static run with a **painted reference horizon**, or with horizon detection off, has no
  such wait.  Neither does a moving run, whose merged horizons are local.  Those overlap in
  either mode.

Keep this in mind when you measure the gain (section 10.4), and say it in the user-facing
help text only as far as it is true.

### 2.4 Bugs found while reading (fix them as part of this work)

- **Videos of more than 9999 frames sort wrongly.**  The pattern is `image_%04d`, so frame
  10000 is `image_10000`.  `ImageSequence` sorts base names as strings, so `image_10000`
  sorts before `image_2000`.  The new source names frames by index (section 4.4), which
  removes the dependence on sorting.  Pick the digit count from the frame count, at least 4.
  Keep `%04d` for videos under 10000 frames, so folders already on disk still match.
- **ffmpeg's tiff encoder defaults to PackBits**, so star's own extracted frames miss
  `MatWrapper`'s uncompressed fast path: warm reads are 2× slower, for about 10% less disk
  (see memory `video-direct-decode-costs`).  `FrameDecodeFormat.ffmpegOutputArguments`
  passes no `-compression_algo`.  The user has decided this becomes a choice at import time
  (section 4.9).

---

## 3. Shape of the change

```
                 ┌──────────────────────── StarCore ────────────────────────┐
  clients ──▶    │  protocol FrameSource                                    │
 (gui, daemon,   │    ├─ DirectoryFrameSource   (image sequence: all ready) │
  cli, pipeline) │    └─ VideoFrameSource       (extraction in background)  │
                 │          ├─ ExtractionScheduler (what to extract next)   │
                 │          └─ ffmpeg workers: 1 in-order sweep, plus jump  │
                 │             workers (any priority if intra-only; only    │
                 │             the user's own frame if long-GOP)            │
                 └──────────────────────────────────────────────────────────┘
```

`FrameSource` replaces the parts of `ImageSequence` that answer "how many frames, what is
frame *i* called, and is it there".  `ImageSequence` keeps its caching role, but takes its
filenames from the source instead of a directory listing.

---

## 4. StarCore design

### 4.1 The `FrameSource` interface

New file `StarCore/Sources/StarCore/FrameSource.swift`.  A sketch; adjust names to the
surrounding code:

```swift
public enum FrameAvailability: Sendable, Equatable {
    case available
    case pending          // will be extracted; not yet
    case failed(String)   // extraction of this frame failed for good
}

/// Where a sequence's original frames come from, and whether each is there yet.
public protocol FrameSource: Sendable {
    /// Total frames.  For a video whose header count was an estimate this can change once,
    /// when extraction finishes (see `FrameSourceEvent.frameCountSettled`).
    var frameCount: Int { get async }
    /// The path frame `index` has, or will have, once extracted.  Never blocks.
    func path(forFrame index: Int) -> String
    /// Non-waiting: is it there now.
    func isAvailable(_ index: Int) -> Bool
    func availability(_ index: Int) -> FrameAvailability
    /// Waiting: returns once the frame is on disk (throws on failure or cancellation).
    /// Asking also raises the frame's priority, where the source can act on that.
    func waitUntilAvailable(_ index: Int) async throws
    /// Callback form of the above, for callers that are not async (C++ loader, AppKit).
    @discardableResult
    func whenAvailable(_ index: Int, _ callback: @escaping @Sendable (Result<Void, Error>) -> Void) -> FrameWaitToken
    /// Ask for frames to be extracted soon.  Never blocks.  No-op for a directory source.
    func prioritize(_ indices: [Int], reason: FramePriorityReason)
    /// Snapshot + live updates, for UIs and the daemon's progress stream.
    func events() -> AsyncStream<FrameSourceEvent>
    var progress: FrameExtractionProgress { get }
    /// Seconds until frame `index` is likely to be available; nil if unknown, 0 if available.
    func estimatedSecondsUntilAvailable(_ index: Int) -> Double?
}

public enum FramePriorityReason: Int, Sendable, Comparable {
    case background = 0      // the in-order sweep
    case pipeline            // an op the graph wants to run next
    case pipelineSample      // frames the temporal static horizon samples (section 4.6)
    case userNearby          // around the frame the user is looking at
    case userViewing         // the frame on screen right now
}

public enum FrameSourceEvent: Sendable {
    case snapshot(available: IndexSet, frameCount: Int, progress: FrameExtractionProgress)
    case framesAvailable(IndexSet)
    case frameFailed(Int, String)
    case progress(FrameExtractionProgress)
    case frameCountSettled(Int)
    case finished
    case failed(String)
}

public struct FrameExtractionProgress: Sendable, Equatable {
    public var extracted: Int
    public var total: Int
    public var framesPerSecond: Double?   // smoothed, for the ETA
    public var isComplete: Bool
    public var accessKind: AccessKind?    // nil for a directory; .seekable: any priority moves the
                                          // extractor; .longGOP: only the user's own frame does
}
```

Requirements:

- `isAvailable` and `path(forFrame:)` are **cheap and synchronous**: a lock and an
  `IndexSet`, no `stat`.  The GUI calls them per filmstrip cell per redraw.
- `waitUntilAvailable` must be **cancellation-aware**.  Cancelling the waiting task removes
  its waiter.  Use `withTaskCancellationHandler` and an `NSCondition` or continuation list
  guarded by a lock, like `DecodedFrameStore`.  Do not park a cooperative-pool thread in a
  blocking wait: see memory `swift-pool-starvation-sample-the-hang` and the
  `shellOutOffPool` comment in `VideoConvert.swift`.  The pool is as wide as the core count,
  and a 3-CPU CI runner wedged on exactly this.
- Give the blocking form needed by the C++ loader a separate, clearly named
  `waitUntilAvailableBlocking(_:)` that is only ever called off the cooperative pool.
- `events()` begins with a `snapshot` so a late subscriber is complete (the daemon's
  `seedFrameStates` does the same for frame states).
- A failed source (ffmpeg dies) fails every pending waiter with the error, not a hang.

### 4.2 `DirectoryFrameSource`

Wraps today's behaviour: list the directory, sort, every frame `.available`, `prioritize`
a no-op, `waitUntilAvailable` returns at once, progress complete.  Image sequences must not
get slower.  `isAvailable` must not `stat` (the files were listed at init, exactly as now).

### 4.3 `VideoFrameSource`

Owns the extraction for one video and one output folder.

- At start it knows the frame count (`videoFrameCount`) and so every frame's future path.
  `frameCount` is that number until extraction ends.
- **Availability is "the file is at its final name".**  Run ffmpeg's image2 muxer with
  `-atomic_writing 1` (present in the bundled ffmpeg 9.0.2 and in `/usr/local/bin/ffmpeg`,
  checked with `ffmpeg -h muxer=image2`), which writes to a temporary file and renames it.
  So a file that exists is complete, and a resume (section 4.7) can trust what is on disk.
  Check the temporary name pattern does not match `supportedImageFileTypes`, so nothing
  ever lists a half-written frame.
- **Detecting arrivals:** on each ffmpeg progress line, `stat` forward from the worker's
  head until the first missing file, and mark those available.  Then `stat` once more when
  the worker exits, because the last progress line can arrive before the last rename.  Do
  not use a directory watcher as the primary signal: `FileSystemMonitor.swift` exists, but
  watchers are platform-specific (Windows and Linux builds exist) and coalesce events.
- **Generate the preview and thumbnail of each frame as it lands**, on a low-priority
  queue.  This is how the filmstrip fills in.  Use the existing
  `ImageAccessor.writeMissingImages(frameIndex:filename:...)`; do not run the whole-sequence
  `writeMissingImages(_:)` sweep until the source reports `finished`.
- **Frame count settling.**  When the sequential worker reaches the end:
  - If ffmpeg wrote fewer frames than estimated, the source emits
    `frameCountSettled(actual)`.  Every pending waiter beyond the end fails with a clear
    error.  Clients must shrink their frame arrays (both GUIs keep one view model per frame).
  - If it wrote **more**, the tail frames were never in the graph.  Prefer to make the
    estimate exact before going to the main screen: when the header has no real
    `nb_frames`, run the `-count_packets` probe (demux only, cheap) instead of trusting
    duration × rate.  For the background mode, require an exact count.  `videoFrameCount`
    already has the tiers; expose which tier answered.
- **Errors.**  A worker that exits non-zero fails the source (or only its range, for a jump
  worker; see below) with ffmpeg's stderr, through the same path `FFmpegRun.finish` uses.
  The GUI shows it as an error, not as a frame stuck "extracting".
- **Cancellation.**  Closing the session stops every worker (`runCancellableFFmpegWithProgress`
  already terminates ffmpeg on cancel).  Keep today's rule: a folder this run made is
  removed only if the user gave up *during the import* (the loading screen's Cancel).
  Closing a session whose extraction is half done keeps the folder, for resume.

### 4.4 Naming and indexing

- Frame index *i* is file `image_<i+1, zero-padded>.<ext>`.  Keep the 1-based numbering so
  existing folders and the `frameIndexToBaseNameMap` convention keep working.
- Width: `max(4, digits(frameCount))`.  Store the width in the persisted state
  (section 4.7), so a reopened folder never has to guess.
- `ImageSequence` takes its `filenames` from the source (`(0..<count).map(path(forFrame:))`)
  instead of listing the directory.  The three places that build `frameIndexToBaseNameMap`
  from `filenames` then keep working unchanged.

### 4.5 Long-GOP vs. seekable videos

**Classification** (`VideoFrameSource.AccessKind`: `.longGOP` / `.seekable`):

- A video is seekable when **every packet of its video stream is a keyframe** (intra-only).
  Check that without decoding:
  `ffprobe -v error -select_streams v:0 -show_entries packet=flags -of csv=p=0`, and compare
  the count of `K` flags with the packet count.  For long files, read the first and last
  few hundred packets only (`-read_intervals`).  This catches ProRes, DNxHD/HR, MJPEG, intra
  HEVC/H.264, CineForm, etc., without a codec list.
- Also keep a codec-name fast path for the dialog's default (the dialog must not wait on a
  long probe): `prores`, `dnxhd`, `mjpeg`, `cfhd`, `ffv1` and similar are seekable;
  `h264`, `hevc`, `av1`, `vp9`, `mpeg2video`, `mpeg4` are long-GOP unless the packet probe
  says otherwise.  `FFmpegCodec` already has the names.
- Add the result to `VideoProbe` (`seekable: Bool?`) so the dialog and the daemon's
  `ProbeVideo` can both use it.

**Why the line is drawn there** (measured, memory `video-direct-decode-costs`): a random
frame of 4K HEVC/H.264 (GOP 60) costs 1.3–2.7 s, because it decodes about 28 frames per seek.
A random ProRes frame costs 0.22 s at 4K and 0.38–0.58 s at 6K.  Sequential decode is
53–190 ms per frame, and most of it is the YUV→rgb48 swscale, not the decode.

**Long-GOP ("sequential") videos:** one in-order sweep worker, start to end, plus **user
jumps only** (decided by the user, 2026-10-27).  A jump to a frame costs about 1.3–2.7 s
there, which is far too slow for the pipeline's out-of-order neighbour reads but fine for
"show me frame 1,400 now".  So:

- Only `userViewing` and `userNearby` requests start a jump on a long-GOP video.
  `pipeline` and `pipelineSample` requests never do; they wait for the sweep.  (The user
  accepts that a static automatic-horizon run on H.264 gains almost nothing, section 2.3.)
- At most `FrameExtractionSettings.maxLongGOPJumpWorkers` jumps run at once (default 1; see
  "Concurrency" below).  A new `userViewing` request **replaces** a jump that is still
  seeking towards a frame the user has left.  Cancel it and start the new one, rather than
  queueing.
- A jump extracts the viewed frame and its `userNearby` neighbourhood as one contiguous range,
  so one seek pays for the cluster.  It begins at the **keyframe at or before** the first
  wanted frame, which ffmpeg's input-side `-ss` does on its own.  Frames decoded between that
  keyframe and the first wanted frame are discarded, not written.
- **Open-GOP streams** (HEVC CRA, H.264 without IDR-only GOPs) can have leading pictures that
  do not decode identically when decoding starts at that keyframe.  A jumped frame must be
  bit-identical to the same frame from the sweep (section 10.1).  If that cannot be
  guaranteed for a stream, begin the jump one keyframe earlier.  If even that fails the
  test, disable jumps for that stream and fall back to sweep-only, logged once.
- The ETA for a frame inside a planned jump is the jump's seek cost (measured, starting from
  the first jump's observed value) plus its in-range position.  For any other frame it is
  `(i − head) / fps`.  The GUI says which (section 6.4).

**Seekable (intra-only) videos:** one in-order sweep worker, plus **jump workers** that the
scheduler starts on demand for any priority, pipeline included:

- A jump worker extracts a contiguous range `[a, b)`:
  `ffmpeg -ss <pts(a)> -i <video> -frames:v <b-a> -start_number <a+1> -atomic_writing 1 …`.
  Input-side `-ss` seeks to the keyframe at or before the time.  For intra-only video that
  is the frame itself.
- **Use real timestamps, not `index / fps`.**  Build a frame→pts table once, by demuxing:
  `ffprobe -select_streams v:0 -show_entries packet=pts_time -of csv=p=0`.  This demuxes
  only, so it is fast even for ProRes.  Variable frame rate and odd start times would
  otherwise land a jump one frame off and write the wrong picture under the right name,
  silently.  The tests must pin this (section 10.1).
- The sweep worker must **skip frames that are already on disk** when it gets there.
  ffmpeg cannot skip mid-run, so the scheduler stops the sweep at the start of the next
  extracted run and restarts it past the end of that run.  This is cheap for intra-only
  video, and the restart cost is one process launch plus one seek.
- The sweep-skip rule above applies to long-GOP jumps too.  There, restarting the sweep past
  a jumped range costs one seek, which is still far cheaper than decoding the range twice.

**Concurrency is a parameter, not a literal** (decided by the user: 1 for now, but easy to
change).  Put every worker limit in one value type, and pass it in instead of writing `1`
at each use:

```swift
public struct FrameExtractionSettings: Sendable, Equatable, Codable {
    /// Extra ffmpeg processes extracting ahead of the sweep on an intra-only video.
    public var maxJumpWorkers: Int = FrameExtractionSettings.defaultMaxJumpWorkers
    /// The same for a long-GOP video, where only the user's own frame starts one.
    public var maxLongGOPJumpWorkers: Int = FrameExtractionSettings.defaultMaxLongGOPJumpWorkers
    public static let defaultMaxJumpWorkers = 1
    public static let defaultMaxLongGOPJumpWorkers = 1
}
```

- `VideoFrameSource.init` takes a `FrameExtractionSettings`, and the scheduler reads its
  limits from there and nowhere else.  A grep for a hard-coded worker count should find
  only these two defaults.
- Make it settable without a code change: a CLI option (`--extraction-jump-workers N`,
  section 8) and an `extraction_settings` field on `OpenVideoRequest` (section 7.1).
  Neither GUI exposes it yet.  A GUI setting would be a `Config` property with all its
  surfaces (memory `config-property-removal-surfaces`), which is not worth it until a
  measurement says the default should change.
- Why 1 for now: each ffmpeg process is single-threaded in swscale, so on this 18-core
  machine more workers extract faster in total, but the pipeline wants those cores once it
  is running.  Measure before raising it (section 10.4), and keep disk reads going through
  `IOWork`'s per-volume limits.  Remember memory `one-heavy-job-at-a-time`: when measuring,
  never run two star runs, test suites or builds at once on this machine.

### 4.6 The scheduler

`ExtractionScheduler` decides what each worker extracts next, from a priority map
`[frameIndex: FramePriorityReason]` plus the sweep:

- `userViewing` > `userNearby` > `pipelineSample` > `pipeline` > `background` sweep.
- **User priorities.**  The GUI calls `prioritize([i], .userViewing)` for the frame on screen,
  and `prioritize(i-k...i+k, .userNearby)` for its neighbourhood (k ≈ the filmstrip's
  visible half-width, or 8, whichever is larger).  A new `userViewing` request **replaces**
  the previous one: the scrubber moving must not queue every frame it passed over.
  Debounce requests from a scrub that is moving (about 150 ms), but make the frame where it
  stops take effect at once.
- **Pipeline sample priority.**  When the frame graph is built for a static tripod with the
  temporal static horizon, the builder asks the source to prioritize exactly the frames
  `TemporalHorizonDetector` will sample.  Factor the sample-index computation out of the
  detector into a function both can call, so they cannot disagree.  This one step is what
  turns a static automatic-horizon run from "no overlap" into "full overlap" on a seekable
  video (section 2.3).
- **Pipeline priority.**  An op that becomes ready but whose frame is missing (section
  5.1) bumps that frame to `pipeline`.
- When a jump finishes and no request is outstanding, the jump worker exits.  Do not leave
  idle ffmpeg processes.
- On a long-GOP source, the scheduler acts only on `userViewing` / `userNearby` (section
  4.5).  It records the rest, so it can say "frame 1400 is being waited on" in the UI and
  logs.

### 4.7 Persistence and resume

A user can quit, or the app can crash, mid-extraction.  The reopened sequence must not look
like a short sequence, and it must not need the whole video extracted again.

- Write a small sidecar, `<frames folder>/extraction.json`, with: source video path, size
  and mtime (to notice a replaced video), frame count, its tier (exact or estimated), digit
  width, `FrameDecodeFormat`, access kind, `complete: Bool`.  Write it at start and when
  extraction completes.  It is the source of truth for "this folder is a video's frames",
  and works for all three clients without touching `config.json`.
- Also record in `Config` that the sequence came from a video, so that `config.json`
  reopen paths (gui `startup(withNewImageSequence:)`, daemon `Session.openConfig`, cli
  `config.json` input) can construct a `VideoFrameSource` and resume.  `Config` has a
  hand-written decoder: add the new keys to it, and to the Mirror-driven round-trip test.
  See memory `config-json-round-trip-loss`, and `config-property-removal-surfaces` for every
  place a `Config` property lives (gui view model, daemon `Mapping`, both protos, Kotlin
  dialog, i18n).  Keep the Config field minimal (e.g. `sourceVideoPath: String?`) and put
  the rest in the sidecar.
- On open: if the sidecar says `complete`, use a `DirectoryFrameSource`, byte-for-byte
  today's behaviour.  If it does not, build a `VideoFrameSource`, mark what is on disk
  available (atomic writes make that safe), and extract the gaps.  If the source video is
  gone or changed, open what is there read-only and say so.  Never delete frames.
- `decodeVideo` today refuses to overwrite (it relies on ffmpeg not overwriting).  The
  resume path must pass explicit ranges instead, so it never rewrites an existing frame.

### 4.8 ETA

`estimatedSecondsUntilAvailable(i)`:

- Keep a smoothed rate per worker (frames per second over the last ~20 frames).  Count only
  frames that worker wrote: a rate that includes frames the sweep skipped would be
  optimistic.
- No jump planned for *i* (either kind of video): `(i − sweepHead) / sweepRate`.
- *i* in a jump: the jump worker's launch-plus-seek latency + `(i − jumpHead) / jumpRate`.
  Measure the latency and start from the first jump's observed value.  Keep it **per access
  kind**: a long-GOP seek costs a GOP's decode, an intra-only one about a frame.
- `nil` before the first rate sample.  The UI then shows an indeterminate indicator.
- Expose the same numbers through `FrameExtractionProgress` so the overall bar can show
  "about 4 min left".

### 4.9 TIFF compression, chosen at import

Decided by the user: whether extracted TIFFs are compressed is an **option at import time**,
presented with the existing TIFF/JPEG question, with a clear description.  This is separate
from background extraction and applies whether that is on or off.

- `FrameDecodeFormat` (`FrameDecodeFormat.swift`) gains
  `public var tiffCompression: TIFFCompression` with cases `.none` and `.packBits`.  JPEG
  ignores it, like `jpegQuality` is ignored for TIFF.  `ffmpegOutputArguments` passes
  `-compression_algo raw` or `-compression_algo packbits` explicitly for both TIFF kinds.
  Both are accepted by ffmpeg's tiff encoder (`ffmpeg -h encoder=tiff`; it also offers lzw
  and deflate).  Do **not** offer deflate: LRTimelapse's deflate TIFFs read at 1.0 s warm
  and 1.4 s cold for a 6K frame, against 117 ms raw.
- **Default: `.packBits`**, which is what every existing import has written (ffmpeg's
  default), so nobody's disk use changes without them choosing it.  `FrameDecodeFormat`
  is `Codable`: decode a missing key as `.packBits` so old saved values keep their meaning.
  Add the field to the `extraction.json` sidecar (section 4.7).
- **Disk estimate.**  `estimatedBytesPerPixel` must depend on the choice.  Uncompressed is
  exact (6 bytes per pixel for tiff16, 3 for tiff8, plus a header).  Keep the measured
  PackBits values (6.1 / 3.1 today, which lean high).  Before relying on them, re-measure
  PackBits on a few night frames: memory says about 10% smaller than raw on night frames,
  while the comment in `FrameDecodeFormat` says ffmpeg "hardly compresses a noisy sky".
  The dialog's estimate has to tell the user the real difference.
  `ProbeVideoResponse` carries per-format bytes per pixel to the Kotlin client, so add the
  uncompressed ones there (section 7.1).
- **Where it appears.**  In both dialogs, a control shown only when a TIFF kind is selected,
  the way the JPEG quality slider is shown only for JPEG: a two-choice picker,
  "Uncompressed (faster)" / "Compressed (smaller)", with a description under it (text in
  section 9).  The disk estimate updates as it changes.
- **Measured basis for the description** (memory `video-direct-decode-costs`, warm reads
  through star's own loader): 4K tiff16 raw 30 ms vs PackBits 63 ms; 6K raw 117 ms vs
  PackBits 222 ms.  So uncompressed reads about twice as fast, for roughly 10% more disk.
  Re-measure at the end and quote the numbers you get, not these.
- CLI: `--tiff-compression none|packbits`, next to the existing `--frame-format` option
  (`StarCli.swift:280`).

---

## 5. Pipeline integration (StarCore)

### 5.1 Ops wait on frames through a dependency, never through `isReady`

Every op that reads an original (horizon detection, keypoints, the homography's inline
keypoint fallback, preview generation, outliers, merge) must not start before its frames
exist.

- Add a `FrameAvailableOp: AsyncOperation` per frame: an op that finishes when the source
  says the frame is available.  Give it zero memory multiplier, so it reserves nothing.
  **Do not run it on the frame queue.**  An op parked there waiting for ffmpeg would take a
  `maxConcurrentOperationCount` slot.  Put it on its own queue, or better, let the source
  finish it from its arrival callback: make it an op that is already "executing" and that
  the source finishes.
- Add it as a dependency of every op that reads that frame's original, including
  neighbours: a homography whose neighbour's keypoints are cached on disk still may read the
  neighbour's original on the fallback path.  Check each op type in `FrameGraphBuilder.build`
  for which originals it touches.
- **Never gate on `isReady`.**  `KeypointLimiter.swift`'s header explains why: a
  readiness answer that changes with no KVO notification latches the op not-ready forever,
  and it wedged the pipeline.  A dependency that finishes is the KVO-correct way.
- For a `DirectoryFrameSource`, add **no** such ops.  Image-sequence graphs must stay
  exactly as they are now.

### 5.2 Backstops

The dependency is the mechanism; these catch whatever was missed:

- `ImageAccessor.loadInt` for `.original` at `.original` size: if the source says pending,
  `await source.waitUntilAvailable(i)` instead of returning nil.  Log at `.w` once per frame:
  an op reaching this point means a dependency was missed, and the log tells you which.
- `DecodedFrameStore.load` (the C++ loader, synchronous on a native thread): look the path
  up in the source.  If the frame is pending, `waitUntilAvailableBlocking`.  This is safe
  only because it never runs on the cooperative pool; keep that true.
- `ImageSequence.getImageInfo()` waits for frame 0.

### 5.3 Graph build while extracting

- `ImageSequenceViewModel.setup` and `Session.buildFrameGraph` build one per-frame object
  (`FrameAirplaneRemover`) for every frame, and report "frames loaded".  Make sure this does
  not read originals (it should only `stat` artifacts).  If anything does, defer it until
  the frame is available.
- `FrameGraphBuilder.build`'s "already done" checks `stat` artifacts in the output dirs,
  not originals.  They stay as they are.
- The frame count can shrink once (section 4.3).  If processing was started before the count
  settled, frames past the end have ops waiting on `FrameAvailableOp`s that now fail.
  Cancel those ops cleanly, without reporting them as an error run, and rebuild the graph's
  tail.  Simplest correct behaviour: in background mode, require an exact frame count up
  front (section 4.3), so the count never changes.

---

## 6. macOS GUI (`gui/`)

### 6.1 Import dialog: `gui/star/VideoImportSheetView.swift`

- Add a `Toggle(localized("ui.video_import_background"), isOn: $extractInBackground)` under
  the format picker.  Its accessibility identifier is `videoimport.background`.
- The default comes from the probe: on when `probe.seekable == true`, off otherwise.  Until
  the probe answers, use the codec-name fast path; the user's own change is never
  overwritten when the probe lands.
- Help text: a `.help(...)` tooltip **and** a short secondary-style caption under the toggle,
  since the warning matters and tooltips are easy to miss.  Text in section 9.
- With a TIFF kind selected, show the compression picker and its description under the
  format picker (section 4.9).  Identifiers: `videoimport.compression.none` and
  `videoimport.compression.packbits`.  The `diskUsage` estimate follows the choice.
- `onImport` becomes `(FrameDecodeFormat, Bool) -> Void` (or pass a small options struct).
  The compression choice travels inside `FrameDecodeFormat`.

### 6.2 Startup: `gui/star/ViewModel.swift:599`

- Background off: today's flow, unchanged.
- Background on: build the `VideoFrameSource`, wait for **frame 0**, the exact frame
  count and the probes (frame rate, codec, pixel format and audio, which already run beside
  the decode), then call `startup(withNewImageSequence:)` with the source.  The loading
  screen (`ImageSequenceLoadingView`) shows only that short wait.
- `ImageSequenceViewModel` gets the `FrameSource`; frames subscribe to its events.

### 6.3 Marking unextracted frames

- **Filmstrip** (`FilmstripView.swift`, `FilmstripImageView.swift`): a cell whose frame is
  pending shows a dimmed placeholder with a small "not extracted" glyph (an SF Symbol such
  as `hourglass`) and no thumbnail.  A frame being extracted right now (inside a jump or at
  the sweep head) gets an activity indicator instead.  Update from `framesAvailable` events,
  not polling.
- **Scrub slider** (`ScrubSliderView.swift`): draw the extracted ranges as a band along the
  track (like a video player's buffered range), coalesced from the `IndexSet`, so the user
  can see where they can go without waiting.
- **Edit and scrub image views** (`FrameEditView.swift`, `FrameEditImageView.swift`,
  `FrameImageView.swift`): when the current frame is pending, show the **wait panel** (6.4)
  in place of the image.  Disable tools that need the original (horizon painter, outlier
  tools) for that frame, and say why in their tooltip.  When the frame lands, the image
  replaces the panel with no user action.
- Navigating to a frame (scrub, filmstrip click, arrow keys, frame-number field) calls
  `prioritize` (section 4.6).  Put that call in one place in the view model where the
  current frame index changes, not in each view.

### 6.4 The wait panel

When the user is on a pending frame:

- "Frame 1,400 is not extracted yet."
- Seekable video: "Extracting it now — about 3 s" with a determinate bar of the jump's
  progress towards that frame.
- Long-GOP video, with a jump to this frame running: as above ("Extracting it now —
  about 3 s").  The seek part of a long-GOP jump has no per-frame progress, so show an
  indeterminate bar until the jump's first frame lands, then a determinate one.
- Long-GOP video, frame not in a jump (the pipeline asked for it, or the jump limit is
  taken): "Extraction is at frame 212; this frame will be reached in about 6 min", with a
  determinate bar of `head / i` and a one-line reason ("H.264 video is extracted in order;
  frames you view are fetched first").
- `nil` ETA: indeterminate indicator and "Estimating…".
- Refresh about once a second from the source's progress.  Do not recompute from the view
  body.

### 6.5 Overall progress

A compact progress strip in the main window while extraction runs: a bar and
"Extracting video: 1,234 of 5,000 frames (about 4 min left)".  Put it in the bottom status
area (`BottomLeftView.swift` / `BottomRightView.swift`).  It disappears on completion, and
on failure it becomes an error that does not go away on its own.  Do **not** use a `.sheet`
for any of this: every `.sheet` in the gui hangs off `BottomRightView`'s edit-mode branch
and shows nothing from scrub mode (memory `gui-sheet-attachment-trap`).

### 6.6 Processing while extracting

The "process" buttons (`ProcessAllFramesButton.swift`, `ProcessRemainingFramesButton.swift`)
stay enabled.  The graph waits on frames (section 5).  The processing-steps view should show
that the run is waiting on extraction, e.g. a status line "waiting for frames: extraction
at 40%", using the existing `StepProgress.status` idea, so a run that looks idle is not
mistaken for a hang.

---

## 7. Daemon and Kotlin desktop client

### 7.1 Proto (`daemon/proto/star.proto` is authoritative)

Edit `daemon/proto/star.proto`, run `daemon/regen-proto.sh`, then
`./gradlew syncProto` in `star-desktop` (`checkProtoSync` fails the build on drift).

- `OpenVideoRequest`: `bool extract_in_background = 5;`
  `TiffCompression tiff_compression = 6;` (new enum: `TIFF_COMPRESSION_PACKBITS = 0`,
  the default and today's behaviour, and `TIFF_COMPRESSION_NONE = 1`), and
  `ExtractionSettings extraction_settings = 7;` with `int32 max_jump_workers = 1;
  int32 max_long_gop_jump_workers = 2;` (0 = StarCore's default; section 4.5).
- `ProbeVideoResponse`: `bool seekable = 8; bool seekable_known = 9;` (the fast path may not
  know), and `double tiff16_raw_bytes_per_pixel = 10; double tiff8_raw_bytes_per_pixel = 11;`
  for the uncompressed estimate.  The existing `tiff16_bytes_per_pixel` and
  `tiff8_bytes_per_pixel` stay PackBits, so an older client keeps reading the same numbers.
- `SessionInfo`: `FrameExtraction extraction = 10;` (absent or complete for sequences).
- New messages:

```proto
message FrameRange { int32 start = 1; int32 end = 2; }   // [start, end)
message FrameExtraction {
  int32 extracted = 1;
  int32 total = 2;
  double frames_per_second = 3;           // 0 = not known yet
  bool complete = 4;
  bool seekable = 5;
  repeated FrameRange available = 6;      // coalesced; full list on snapshot
  string error = 7;                       // non-empty: extraction failed
}
message FramesAvailable { repeated FrameRange ranges = 1; }
message PrioritizeFramesRequest { string session_id = 1; int32 viewing = 2; repeated FrameRange nearby = 3; }
message PrioritizeFramesResponse {}
message FrameEtaRequest  { string session_id = 1; int32 frame_index = 2; }
message FrameEtaResponse { bool available = 1; double seconds = 2; bool known = 3; double fraction = 4; }
```

- `ProgressEvent` gains `FrameExtraction frame_extraction = 11;` (throttled to about 4 per
  second, like `StepProgress`) and `FramesAvailable frames_available = 12;` (batched).
  `Processing.StreamProgress` already seeds a new subscriber (`seedFrameStates`); seed a
  full `FrameExtraction` snapshot the same way.
- New RPCs in `daemon/Sources/stard/Dispatcher.swift`: `Frame.Prioritize`,
  `Frame.GetEta`.
- `Frame.GetPreview` / `Frame.Get` for a pending frame return a distinct "not extracted"
  result (a field, not a transport error), so the client shows its placeholder rather than
  an error.  Look at how `FrameHandlers.getPreview` reports a missing preview today and
  extend it.

### 7.2 Daemon (`daemon/Sources/stard/`)

- `Session.openVideo`: background off → today's path.  Background on → build the source,
  wait for frame 0 and the exact count, build the session with the source, send `done`.
  Extraction continues after the open stream has ended, so the source must belong to the
  `Session`, not to the open handler's task.  Cancelling the *open* stream still cancels
  everything; closing the session stops the workers.
- Forward the source's events into `ProgressEvent`s for `StreamProgress` subscribers.
- `Session.openConfig`: resume per section 4.7.

### 7.3 Kotlin (`star-desktop/`)

- `ui/dialogs/VideoImportDialog.kt`: the same checkbox, default and help text, from
  `ProbeVideo`'s new fields.  Also the same TIFF compression picker and description, shown
  for the TIFF choices.  Its estimate comes from `domain/VideoImport.estimatedBytes`, which
  must pick the raw or PackBits bytes per pixel.  `confirmVideoImport` / `openVideo` /
  `SessionRepository.openVideo` / `StarClient.openVideo` carry both choices.
- `ui/app/AppViewModel.kt`: with the flag on, go to the sequence screen when `OpenVideo`
  completes (it now completes early).
- `ui/sequence/Filmstrip.kt`, `FrameCells.kt`: placeholder cells for pending frames.
- `ui/sequence/ScrubSlider.kt`: the extracted-ranges band.
- `ui/sequence/FrameImageView.kt`, `edit/FrameEditView.kt`, `edit/HorizonPainterView.kt`:
  the wait panel and disabled tools, as in 6.3/6.4.  Poll `Frame.GetEta` about once a
  second only while the panel is shown.
- `ui/sequence/SequenceViewModel.kt`: keep an availability set from the events; call
  `Frame.Prioritize` (debounced, section 4.6) where the current frame changes.
- `ui/sequence/BottomStatus.kt`: the overall bar and "N of M".
- Compose has no Linux accessibility tree, so black-box GUI tests are macOS/Windows only.
  Compose UI tests run headless everywhere (memory `gui-test-automation-feasibility`).

---

## 8. CLI

The CLI always processes. Add `--extract-in-background` / `--no-extract-in-background`
(default: on when seekable, else off, the same rule as the dialog) and build the source
instead of calling `decodeVideo`.  Also add `--tiff-compression` (section 4.9) and
`--extraction-jump-workers N` / `--extraction-long-gop-jump-workers N`, which fill
`FrameExtractionSettings` (section 4.5).  A CLI run never makes a user jump, so the
long-GOP one only matters for measuring.  Keep printing the decile progress lines.  When the
extraction finishes, print one line saying how long the run waited on frames, so the gain
can be measured from the CLI alone.  `-s`, `-L` and friends: see memory
`cli-unread-flag-decisions` for how flags are wired.  The CLI's Xcode project cannot link;
build with `swift build` (memory `cli-xcodeproj-ld-broken`).

---

## 9. Strings (i18n)

All four clients read one JSON catalogue per language in
`StarCore/Sources/StarCore/Resources/Localizations/*.json` (memory `i18n-architecture`; run
`i18n/check.py`).  Add English, then fill every language; the checker fails on missing keys.
Proposed English:

- `ui.video_import_background`: "Extract video in background"
- `ui.video_import_background_help` (caption and tooltip):
  > Start working while the video's frames are still being extracted.  ProRes and other
  > formats that store every frame on its own can jump to any frame quickly, so the frames
  > you look at are extracted first.  H.264, H.265 (HEVC) and similar formats store most
  > frames as changes from earlier ones.  star can still fetch the frame you are looking at,
  > but each jump takes a few seconds, and processing has to wait for extraction to reach
  > each frame in order.  If you will draw or paint horizons by hand, you will wait every time
  > you move to a new part of the video, so for these formats it is usually quicker to
  > extract the whole video first.
- `ui.frame_not_extracted`: "Frame %d is not extracted yet."
- `ui.frame_extracting_now`: "Extracting it now — about %@"
- `ui.frame_extraction_in_order`: "Extraction is at frame %d; this frame will be reached in about %@."
- `ui.frame_extraction_in_order_reason`: "This video is extracted in order; frames you view are fetched first."
- `ui.tiff_compression`: "TIFF compression"
- `ui.tiff_compression_none`: "Uncompressed (faster)"
- `ui.tiff_compression_packbits`: "Compressed (smaller)"
- `ui.tiff_compression_help` (caption under the picker; put the re-measured numbers in it):
  > Uncompressed frames are read about twice as fast while star processes them, so a run
  > finishes sooner, but they take roughly 10% more disk space.  Compressed frames save
  > that space.  The compression is lossless: both give exactly the same picture and the
  > same results.
- `cli.help.tiff_compression`, `cli.help.extraction_jump_workers`,
  `cli.help.extraction_long_gop_jump_workers`.
- `ui.frame_extraction_estimating`: "Estimating…"
- `ui.extracting_video_progress`: "Extracting video: %d of %d frames"
- `ui.extracting_video_eta`: "about %@ left"
- `ui.extraction_failed`: "Extracting the video failed: %@"
- `ui.tool_needs_extracted_frame`: "Available once this frame is extracted."
- `ui.processing_waiting_for_frames`: "Waiting for frames (extraction at %d%%)"
- `cli.extract_in_background_help`, `cli.waited_for_frames`: CLI equivalents.

---

## 10. Testing and verification

### 10.1 StarCore unit tests (`StarCore/Tests/StarCoreTests/`)

Use small synthetic videos made with the bundled ffmpeg in the test (`testsrc2`, a few dozen
frames, small size).  Make one ProRes (seekable) and one H.264 with a GOP longer than the
clip (sequential).  Add a **variable frame rate** clip and one with a non-zero start time.

- `DirectoryFrameSource`: everything available, no added latency, same filenames and order
  as today's `ImageSequence` for an existing fixture.
- Classification: ProRes → seekable; long-GOP H.264 → long-GOP; all-intra H.264
  (`-g 1`) → seekable by the packet probe even though the codec name says otherwise.
- `VideoFrameSource` sequential: availability grows monotonically.  `waitUntilAvailable` on
  the last frame returns only after its file is complete.  The non-waiting call returns
  false before and true after.  Cancelling a waiter removes it.
- Seekable jump: prioritize frame N−5 right after start; it is available well before the
  sweep could have reached it.  **Every jumped frame is bit-identical to the same frame from
  a plain full extraction**, including on the VFR and offset-start clips.  This is the test
  that catches an off-by-one seek.
- Long-GOP user jump: on the H.264 clip, `prioritize(_, .userViewing)` near the end starts
  one jump; `.pipeline` and `.pipelineSample` requests start none.  The jumped frames are
  **bit-identical** to the sweep's.  Add an open-GOP HEVC clip
  (`-x265-params open-gop=1`) for the same check (section 4.5).  A second `userViewing`
  request cancels a jump that is still seeking.
- Worker limits: with `FrameExtractionSettings` set to 0 / 2 jump workers, the number of
  live ffmpeg processes never exceeds `1 + limit`.  Also test that an idle source has none.
- TIFF compression: `.none` writes files whose header says compression 1 and that take
  `MatWrapper`'s uncompressed fast path; `.packBits` writes 32773.  Both decode to identical
  pixels.  A stored `FrameDecodeFormat` without the key decodes as `.packBits`.  The disk
  estimate differs by the expected ratio.
- Sweep skip: after a jump, the sweep never rewrites jumped frames (check mtimes or inode)
  and the final folder is identical to a full extraction.
- Count settling with an estimated count; ffmpeg failure fails all waiters; resume from a
  half-extracted folder plus `extraction.json` extracts only the gaps.
- More than 9999 frames: naming width and order.  The width logic can be tested without a
  10000-frame video.
- `FrameAvailableOp` in a graph: an op depending on a pending frame does not start; it
  starts after arrival; the frame queue's slots are not consumed while waiting (run with
  `numberOfFramesToProcessConcurrently = 1` and show no deadlock, the case that wedged
  `KeypointLimiter`).

### 10.2 Daemon tests (`daemon/Tests/StarDaemonTests/`)

`OpenVideo` with `extract_in_background` returns `done` before extraction completes.
`StreamProgress` seeds a `FrameExtraction` snapshot and then sends deltas.  `Frame.Prioritize`
moves a jump on a ProRes clip.  `GetPreview` on a pending frame returns "not extracted".
There are existing video tests to copy from (`VideoCapabilitiesTests`,
`CancellableFFmpegTests`).

### 10.3 Gherkin

Add a scenario per client to the matrix (memory `gherkin-scenario-matrix`; desktop runner
`star-desktop/src/gherkinTest/.../DesktopFeatureRunner.kt`, cli `cli/Tests/GherkinTests/`):
open a short ProRes clip in background mode and process it; the output must be
**bit-identical** to the same clip opened with background mode off.  This is the
correctness bar: streaming must change when work happens, never what it produces.

### 10.4 Measuring the gain (do this before calling it done)

On a real video (the user's inputs are mostly LRTimelapse ProRes exports; there is a ProRes LT
source under `/sp`, see memory `video-direct-decode-costs`), compare wall clock from "Import"
to output written, background on vs. off.  Do this for:
(a) static + automatic horizon, ProRes; (b) moving, ProRes; (c) static + automatic horizon,
H.264, where the expected gain is about zero (section 2.3), so say so; (d) any of them with a
painted reference.  Also check that the jump worker count does not slow the pipeline once it
is running.  End-to-end runs on this Mac vary by about 90 s on identical configs (memory
`perf-measurement-noise-floor`), so repeat runs and report the spread, and run only one
heavy job at a time (memory `one-heavy-job-at-a-time`).  If a run looks hung at 0% CPU,
check `ps -o stat` for `T` before debugging (memory `processes-sigstopped-on-this-mac`).

### 10.5 Looking at the GUI

The gui cannot be driven without accessibility access.  To look at the new placeholder cells,
the scrub band and the wait panel, render the views to PNG from a throwaway XCTest (memory
`gui-view-snapshot`).  Build in a worktree per memory `gui-worktree-build` (symlink the
gitignored opencv / StarDecisionTrees / gui/videos artifacts; `-scheme star`, never
`-target Star`).

---

## 11. Order of work

Each phase should land green (StarCore, daemon, gui and Kotlin builds, plus tests) before the
next.

1. **`FrameSource` + `DirectoryFrameSource`**, and `ImageSequence` taking filenames from it.
   No behaviour change.  Fix the >9999-frame naming here.
2. **`VideoFrameSource`, in-order sweep only**, with atomic writes, arrival detection, events,
   ETA, `extraction.json` and resume.  `decodeVideo` becomes a thin wrapper ("start a source
   and wait for `finished`") so the old path keeps working through the new code.
3. **Pipeline integration**: `FrameAvailableOp` dependencies, the backstops, previews as
   frames land, the count rules.  CLI flag.  Measure (c) and (d) of 10.4.
   Also the TIFF compression option in `FrameDecodeFormat`, the CLI and the probe's
   estimates (section 4.9).  It is independent of streaming and can land first on its own.
4. **Seekable**: classification, pts table, jump workers, `FrameExtractionSettings`,
   scheduler, temporal-horizon sample prioritization.  Then long-GOP user jumps, with the
   open-GOP check.  Measure (a) and (b).
5. **macOS GUI**: dialog, early hand-off, placeholders, scrub band, wait panel, overall bar,
   prioritize-on-navigate.
6. **Daemon + proto + Kotlin**: the same features.
7. **i18n fill, Gherkin scenarios, docs** (`README.md`, `docs/features.html` if it lists import
   behaviour).

Phases 5 and 6 are independent once 4 is in, and could run in parallel worktrees.

---

## 12. Decisions the user has made (2026-10-27)

These were open questions in the first draft.  The user has answered them, and the sections
above already reflect the answers.  Do not reopen them without asking.

1. **Static automatic-horizon runs on H.264 gain almost nothing** (section 2.3): accepted.
   Do not compute the static horizon from a partial set of frames, since that would change
   results.  Long-GOP pipeline requests wait for the in-order sweep.
2. **Long-GOP jumps for the user's own frame: yes**, in this project (section 4.5).  Only
   `userViewing` / `userNearby` requests start them, with at most
   `maxLongGOPJumpWorkers` at a time, and a jumped frame must be bit-identical to the
   sweep's.
3. **TIFF compression is a choice at import time**, presented with the TIFF/JPEG question,
   with a clear description (section 4.9).  The default stays PackBits, today's behaviour;
   that default is this plan's call, not the user's, so mention it when you hand the work
   back.
4. **One jump worker by default, as a parameter**: the limits live in
   `FrameExtractionSettings` with named defaults, passed in, and overridable from the CLI and
   the proto without a code change (section 4.5).  Never a literal `1` at a use site.
