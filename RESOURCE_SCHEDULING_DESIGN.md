# Resource-aware scheduling — replacing "frames at once" with per-resource limits

A design and handoff document. It is written for whoever implements it, and assumes no
memory of the session that produced it: everything below was measured or read from the
code on 2026-10-03, on develop at `e6d04160` (the fused, in-place GPU merge — see the
follow-up section of `GPU_MERGE_BATCHING_FIX.md`, which you should read first).

The short version: star sizes its concurrency with one number,
`numberOfFramesToProcessConcurrently`, defaulted to the physical core count. That made
sense when every op was CPU-heavy. With GPU keypoints and GPU merges it no longer lines up
with any real bottleneck — on the machine this was measured on, the number the user set
was not even the limit that applied. This document replaces it with a limit per resource
(memory, CPU, GPU, and each disk), a single user-facing setting that scales all of them,
and a status line that says which one is actually holding the run back.

## Decisions already made

Made by Brian on 2026-10-03, and not to be re-litigated without asking him:

1. **The new setting defaults to Full** — use everything the machine has. Dialling down
   is the user's choice.
2. **Don't write the full-size intermediate TIFFs** (`.starAligned`, `.earthAligned`)
   **unless something later actually reads them.** See "Intermediate TIFFs" below for
   exactly what reads them today.
3. **Patch the OpenCV build** so its parallel loops inherit the calling thread's QoS.
   Without this, lowering star's QoS does not lower OpenCV's, and the lighter settings
   cannot actually yield the CPU to other apps. See "The OpenCV QoS patch".

## What was measured

### The machine and the run

- **Machine.** M5 Max Mac Studio (`Mac17,14`) with 36GB of unified memory.
  - CPU: 18 cores in two tiers, `hw.perflevel0` "Super" ×6 and `hw.perflevel1`
    "Performance" ×12. There is no tier named "Efficiency".
  - GPU: 32 cores; `recommendedMaxWorkingSetSize` 30.2GB, `maxBufferLength` 22.6GB.
  - Disk: the internal SSD has 26GB free. The sequence and its temp dir live on
    `/Volumes/rp`, a USB SSD (Oyen "U32 Shadow") on a **5Gb/s** link.
- **Sequence.** 1911 frames, 7008×4672 16-bit RGB: 196MB raw per frame, and 187MB as
  star's `workingFrameBytes`. Source `/Volumes/rp/tmp/LRT_11_30_2024-a7iv-1-aurora-topaz`;
  temp dir `star_temp_LRT_11_30_2024-a7iv-1-aurora-topaz` next to it, already 229GB.
- **Settings.** Moving tripod (`tripodHeadWasMoving = true`), so the earth is aligned and
  not static-merged. Automatic mode without outliers. Horizon detection on, 8 aligned
  neighbours, all three GPU toggles on.
- **Build.** The GUI, built locally from `e6d04160`.

### Throughput did not follow the frame count

Log: `~/Library/Logs/star/Star-logs-2026-10-03-15-10-38.txt`. This run was entirely in
the merge phase (keypoints, homographies and horizons were already on disk).

| frames setting | frames completed per minute | median per-frame time (star merge start → complete) |
|---|---|---|
| 8 | 15–19 | 24.2s |
| 16–17 (the saved config had 17) | 16–17 | 23.5s |

Per-frame time is flat, so doubling the frames should have doubled throughput by
Little's law; it did not. At 16 frames:

- **CPU:** star was at 230–283% CPU, i.e. 2.3–2.8 of 18 cores.
- **GPU:** device utilisation (`ioreg -c AGXAccelerator`, `PerformanceStatistics`) sat
  around 88% in bursts about half the time, and is **unattributed** — see open
  questions.
- **Memory:** RSS was ~8.6GB of 36GB.

### What actually limited it: the memory ledger

- **The ledger was full.** It sat at **27,540MB = 7 × 3,934MB** for the whole run. The log
  has 170 `MemoryMonitor: waiting to reserve 3934MB` lines in its first 12 minutes. With a
  31,334MB budget (36GB × 0.85), no 8th merge op could start, whatever the frame count.
- **Each merge op reserves 3,934MB = 21 × 187MB.** The 21 is `mergeMemoryMultiplier` (6)
  plus `residentBuildExtraMultiplier`, which is `max(aligned − 1, statics − 1)` =
  `max(7, 15)` = 15.
  - That 15 is for the 17-source static-earth merge, which **never runs on a
    moving-tripod sequence**: the earth is aligned with 8 neighbours instead.
  - Without it each merge op reserves 13× (2.43GB), and 12 fit.
- **The keypoint phase was capped at 7 the same way.** Two earlier runs of the same
  sequence (`…13-43-04.txt` at 18 frames, `…14-29-09.txt` at 12) both show
  `KeypointLimiter … 7 concurrent keypoint ops — budget fits 7 … → bound by memory
  budget`, and 60–135 keypoint ops a minute either way.
  - The keypoint reservation (42× at full resolution, 21× at the 1.5 divisor these runs
    used) was measured on the **CPU** SIFT path (`Config.keypointMemoryMultiplier`
    comment).
  - Earth (AKAZE) ops measured about half of sky but are charged the same.
  - The GPU SIFT and AKAZE ports have never been measured at all.

### What limits it next: the disk

Per-frame stage times in the merge phase (median over 169 frames, 15:11–15:22 in the run
above; the 8- and 16-frame periods agree to within half a second):

| stage | time |
|---|---|
| star-aligned merge (8 neighbour decodes + fused GPU merge) | 4.5–4.8s |
| save star-aligned TIFF | 6.2–6.4s |
| earth-aligned merge (same 9 files, page-cache hits) | 0.3s |
| save earth-aligned TIFF + composite (masks, feather, blend) | 6.1–6.5s |
| save auto-processed TIFF + hard link into the output folder (`loadingImages1` → `complete`) | 6.3–6.5s |

- **Writes per frame:** the star-aligned TIFF (181MB), the earth-aligned TIFF (175MB) and
  the auto-processed TIFF (181MB, hard-linked as the output frame), plus three JPEG
  previews. `iostat` showed the USB drive moving 180–230MB/s in total.
- **What a save costs.** Each one is `cv::imwrite` with OpenCV's default TIFF settings
  (LZW with a horizontal predictor), then `fsync`, then rename
  (`MatWrapper.cpp` `writeMatAtomically`). The same 196MB TIFF save took **1.5s** to the
  internal SSD and **7.3s** to the USB drive while the run was using it.
- **LZW does nothing on this data.** It produced 196.7MB for a 196.4MB raw frame, and
  181MB (8% smaller) only where warp borders are black. It also means **no TIFF star
  writes can be read back through the fast direct reader**
  (`MatWrapper.cpp` `tiffReadDirect` takes uncompressed only), so every re-read goes
  through `cv::imread`. One re-read of an aligned TIFF took 145s while the run was
  saturating the drive.
- **Decode cost.** A cold decode of a 196MB original took 0.48–0.60s; a page-cache hit
  took 0.02–0.03s.
- **Repeated decodes.** Over a moving run, each original is decoded about **21 times**
  (once per stage that needs it, as base and as everyone's neighbour). Within one merge
  op, the earth build re-decodes exactly the 9 files the star build just decoded.

### Rough per-resource ceilings, merge phase, this machine

| resource | per frame | capacity | ceiling |
|---|---|---|---|
| disk | ~700MB moved (540MB written + reads past the page cache) | ~200–230MB/s mixed | ~17–19 frames/min — **what was observed** |
| CPU | ~9 core-seconds | 18 cores | ~120 frames/min |
| GPU | ~0.2s (two fused merges) | one device | ~300 frames/min |
| memory | ~1.2GB actually held per op in flight | 31GB budget | ~25 ops; the ledger allows 7 |

So on this setup the merge phase is disk-bound, and more concurrency cannot fix that.
Fewer bytes per frame can.

### Reproducing these numbers

- **Stage timings.** Pair these log lines per frame and type:
  - `frame N creating aligned image of type X` → `frame N got alignment result … for type X`
    (the merge);
  - → `frame N got result WarpedImageResult … for star aligned image` (the star save);
  - `frame N transitioning to state loadingImages1` → `… complete` (the final save).
  - Merge throughput: count `writing out a successfully aligned image` per minute.
  - The ledger: `MemoryMonitor: waiting to reserve` and `reservation granted` lines.
- **GPU:** `ioreg -r -d 1 -w 0 -c AGXAccelerator`, the `PerformanceStatistics` →
  `Device Utilization %` field. Per-process `AGXDeviceUserClient` counters do not report
  star's compute work.
- **Disk:** `iostat -w 1 disk5` (the physical disk behind `/Volumes/rp`).
- **CPU and memory:** `ps -o %cpu,rss -p <pid>`.
- **A single merge in isolation:** `GPUOpsConcurrencyStressTests.testAlignedMergeTimeAndFootprintAtRealScale`
  (`swift test -c release --filter …`) prints time and peak footprint for one realistic
  33MP merge, alone and four at a time, CPU against GPU.

## How concurrency works today

The facts the design depends on, with where to find them.

- **One queue for every op type.** `FrameGraphBuilder.queue` is a single `OperationQueue`
  (`FrameGraphBuilder.swift:76`) whose `maxConcurrentOperationCount` is
  `numberOfFramesToProcessConcurrently` (`:103`, set from `update(from:)`).
  - It bounds **running ops of any type**, not frames. The whole graph for the range is
    built and queued at once.
  - Ops that reserve no memory (homography, validation) compete for the same slots as the
    expensive ones.
  - There is a separate `previewQueue` of 3 for GUI preview ops (`:87`).
- **An op's lifecycle** is `AsyncOperation.start()` (`AsyncOperation.swift:101`):
  1. `hasWorkToDo()`;
  2. `acquireExecutionSlot()` (`:131`) — only `KeypointOp` has one, the `KeypointLimiter`;
  3. `MemoryMonitor.shared.reserve(bytes: workingFrameBytes × multiplier)` (`:136`);
  4. `asyncExecute()`, then release.

  An op waiting in step 2 or 3 is still occupying a queue slot.
- **Phase barrier.** `AlignmentValidationOp` depends on every homography op, and every
  outlier and merge op depends on validation. So horizons, keypoints and homographies
  finish for the **whole sequence** before any merge starts.
  - Phase A (horizon detection, horizon merge, keypoints, homography) and phase B
    (outliers, merges, saves) have completely different resource profiles.
- **Defaults and caps.**
  - `numberOfFramesToProcessConcurrently` defaults to `PhysicalCores.count`
    (`Config.swift:901`).
  - The GUI field caps it at `processorCount − 1`: `RightPanel.swift:769` passes
    `processorCount` as `maxValue`, and `EditableNumberView.swift:116` accepts only
    `newVal < maxValue`. So 17 on this Mac.
- **`KeypointLimiter`** (`KeypointLimiter.swift`) is an async execution gate with FIFO
  waiters and a live `set(max:)`. It is the pattern to copy.
  - Its limit (`Config.keypointConcurrency`, `Config.swift:1944`) is the minimum of the
    frames setting, `fixed budget ÷ (workingFrame × effectiveKeypointMemoryMultiplier)`,
    and `maxConcurrentKeypointOps`.
- **`MemoryMonitor`** (`MemoryMonitor.swift`, an actor).
  - Budget: `physical × maxMatMemoryFraction`. The fraction defaults to 0.85
    (`Config.swift:453`).
  - A "narrowed" budget is computed from available memory and a realized-vs-reserved
    ratio, but it can **only shrink the budget, never raise it**. So a ledger that
    over-reserves 3× still binds at the fixed budget.
  - Per-op multipliers live in `Config`:
    - `effectiveKeypointMemoryMultiplier` (`:516`);
    - `mergeMemoryMultiplier` 6 and `outlierMemoryMultiplier` 9 (`:619–620`), plus
      `residentBuildExtraMultiplier` (`:1862`) and `concurrentLoadExtraMultiplier`;
    - the horizon multiplier, `max(7, ⌈900MB / frame⌉)`.
  - **Not on the ledger:** GPU buffers, the keypoint cache, the final-horizon-mask cache.
- **`NativeWork`** (`NativeWork.swift`) runs blocking native calls on a concurrent queue
  at `.userInitiated`.
  - It is gated by an `AsyncSemaphore` sized from `TaskRunner.maxConcurrentTasks`:
    `activeProcessorCount − activeProcessorCount/4`, so **14** here.
  - That size is fixed at first use and cannot change during a run. The CLI's `-n` also
    sets it, before first use; the GUI and the daemon never do.
- **GPU.** `MetalGPUBackend.gpuSlots` is a `DispatchSemaphore(value: 8)`
  (`StarCpp/Sources/StarCppBridge/GPUOps.swift:200`) around every GPU entry point.
  - Every entry point commits to one `MTLCommandQueue` and blocks in
    `waitUntilCompleted`, on a `NativeWork` thread.
  - The slot count is fixed for the life of the process.
- **Blocking work still on the Swift cooperative pool.** `Task.detached` drops actor
  isolation but stays on the pool. All of these block one of its core-count threads for
  seconds:
  - `ImageAccessor.saveInt` (`ImageAccessor.swift:421`) — every TIFF/JPEG save;
  - StarCore `ImageCache.loadImage`'s decode;
  - `KeypointCache` YAML parses, and the keypoint YAML write after detection;
  - `CombinedHorizonDetector.detect`, including its three single-threaded Random Walker
    solves per frame;
  - `HorizonAccumulator.accumulate`;
  - the outlier/blob pipeline and the `removeAirplanes` / `computeRemovalMask` / `blend`
    pixel loops;
  - SQLite (`HomographyDatabase`).
- **OpenCV ignores star's QoS.** OpenCV's parallel backend on macOS is GCD:
  `cv::parallel_for_` → `dispatch_apply_f` on
  `dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)`
  (`opencv/opencv/modules/core/src/parallel.cpp:595`). Its workers therefore run at
  default QoS whatever star's thread QoS is. `cv::setNumThreads(n > 1)` has no effect on
  this backend (`ImageAligner.cpp`, comment above `medianMergeTyped`).
- **Serialisation points:**
  - `StarAlignedHorizonMaskCache` (`StarAlignedHorizonMask.swift:88`) is one process-wide
    actor, and every frame's 8 nearest-neighbour mask warps run inside it.
  - `HorizonAccumulator` (static sequences).
  - `AlignmentValidationOp`, one op for the whole sequence.
- **What can change mid-run.** `FrameGraphBuilder.update(from:)` runs on every
  `ConfigManager.update` and re-applies the queue width, `KeypointLimiter`, the
  `MemoryMonitor` budget and the cache sizes.
  - `NativeWork`'s width, `gpuSlots`, the preview queue, the `FileSystemMonitor` sizes,
    and each already-queued op's reservation do **not** change.

## Diagnosis

1. **The user's setting is not the limit that applies.** The memory ledger is, and its
   estimates do not match today's code paths:
   - the merge and outlier ops include the static-earth term on moving runs;
   - earth keypoint ops are charged as sky;
   - nothing was ever measured on the GPU ports.

   Because the ledger can only bind at the fixed budget, an estimate that is 3× too
   large costs two thirds of the concurrency.
2. **Storage is a resource star does not model**, and it bounds the merge phase on
   anything slower than an internal NVMe:
   - three fsynced full-size TIFF writes per frame, two of them intermediates nothing reads
     in the default mode;
   - about 18 full-size decodes per merge op, half of them repeats;
   - LZW for no size benefit, which also locks every re-read out of the fast path.
3. **One number cannot fit both phases.** Phase A is GPU, CPU and memory; phase B is disk.
4. **Blocking work on the cooperative pool** caps how much can usefully run regardless of
   any setting, and starves the async plumbing around it (`NativeWork.swift`'s header
   comment explains the failure mode).
5. **There is no real way to dial star down.** Lowering the frame count does nothing
   while the ledger binds, the limits that would matter (`NativeWork`, `gpuSlots`) are
   fixed, and OpenCV ignores QoS.

## Design

### Principles

- **Memory decides how much is in flight; per-resource gates decide what runs at once;
  the user's setting scales both.**
- **Gates sit where the resource is used, not around whole ops.**
  - A merge op reads (disk), then merges (GPU), then saves (disk). Holding a disk slot
    through its GPU phase would waste it.
  - Only memory is held for an op's whole life, because the op holds the data that long.
- **Every limit can change during a run**, the way `KeypointLimiter.set(max:)` already does.
- **Memory estimates follow the code path actually taken**, and measurement corrects them.

### Resources and their gates

| resource | gate | where it is acquired | today | after |
|---|---|---|---|---|
| memory | `MemoryMonitor` ledger | `AsyncOperation.start()`, per op (unchanged) | fixed multipliers, some wrong | per-path estimates, see below |
| CPU | `CPUWork` (`NativeWork`, generalised) | around each blocking CPU call | 14 slots, `.userInitiated`, fixed | width and QoS from the setting, live |
| GPU | the GPU gate (`gpuSlots`, made resizable) | each GPU entry point in `GPUOps.swift` | 8, fixed | width (and an optional duty cycle) from the setting, live |
| each disk | `IOWork`, one gate per volume | each full-size decode and each save | none | width and I/O policy from the setting, live |
| pipeline depth | the `OperationQueue` width | — | the user's frame number | large by default (e.g. 4 × cores); a cap only in Custom |

**Notes for the implementer:**

- **One resizable gate type.** Implement one async gate (FIFO waiters, `acquire`,
  `release`, `set(max:)` that wakes waiters, cancellation-safe) and build `CPUWork`,
  `IOWork` and ideally `KeypointLimiter` on it.
  - The GPU gate is acquired from native threads inside C++ calls, so it needs a
    *blocking* resizable gate (an `NSCondition`-based counter). A `DispatchSemaphore`
    cannot be resized.
- **How C++ decodes get gated.** C++ decodes happen inside merge calls through the
  registered loader (`image_cache_load` → the Swift closure in
  `StarCore/ImageCache.swift`). That closure runs synchronously on the native thread, so
  it is where a blocking per-volume read acquire goes.
  - This cannot deadlock: a read slot is held only for the read itself, which waits on
    nothing else.
- **Volume identity.** Use `statfs` → `f_fsid` (or `f_mntonname`) of the path, cached per
  directory. Source, temp and output may be three different volumes.
- **Pipeline depth.** With memory doing admission, the queue can be wide: ops suspended in
  `reserve()` hold no thread.
  - Keep the `KeypointLimiter` safety argument intact (its `max` must not exceed the queue
    width).
  - Keep a Custom cap for debugging and for users who want today's behaviour.

### Memory estimates

- **Merge and outlier ops.** Charge the static-earth build only when it will run — earth
  static-merged, i.e. `!tripodHeadWasMoving` (see the `alignmentType == .earth,
  !config.tripodHeadWasMoving` branch in `FrameAlignmentProcessor.swift`).
  - Callers today pass `frame.getStaticNeighborFrames().count` unconditionally:
    `FrameGraphBuilder` (both MergeOp builders), `FrameSaveQueue`, and the outlier ops.
  - Expected on the reference sequence: 21× → 13×, and 7 → 12 merge ops admitted.
- **Keypoint ops.**
  - Split the estimate by type (sky / earth) and by path (GPU port / OpenCV).
  - Measure the GPU paths first, with the method in the `keypointMemoryMultiplier`
    comment: one op per fresh process, real `ia_find_features`, 33MP and 42MP,
    divisors 1, 1.5 and 2.
  - `KeypointLimiter`'s memory-derived count should then come from the per-type numbers
    (or step aside in favour of the ledger plus an explicit cap). Decide which, and write
    down why.
- **Per path, not per op type.** The GPU and CPU merge paths hold different things: GPU,
  the decoded neighbours plus the output; CPU, warps plus transients. Keep the estimate
  for each path, even when they come out similar. `MemoryProbe` (`--log-op-memory`)
  catches under-reservation in a run; size estimates downward only from fresh-process
  measurements (its own doc comment says why).
- **Optional, phase 4:** let the effective budget rise above the fixed budget while the
  realized ratio is persistently low and `realityBlock()` is clear, capped (say 1.25×).
  Only do this if correct estimates still leave real headroom unused.

### Intermediate TIFFs (decision 2)

`.starAligned` and `.earthAligned` are written at full size by
`FrameAlignmentProcessor.loadOrCreateAlignedImage` (the `imageAccessor.save` at
`FrameAlignmentProcessor.swift:1064`), and `loadOrCreateAlignedImage` also *reads* them as
a cache before computing (`:741`).

**Who reads them today:**

- **The merge op itself, in outlier modes.** In `.automatic(true)` and `.selective`,
  `OutlierOp` → `loadOrCreateSubtractionImage` (`FrameAirplaneRemover.swift:1913`)
  creates both. The merge op then reloads them: `createAutoProcessedImage` (`:1448`) in
  `.automatic(true)`, `finishSelective` (`:627`) in `.selective`.
- **Selective re-renders.** Every re-render after the user edits outliers goes through
  `finishSelective` and reloads them.
- **Resume.** An interrupted run finds them and skips the merge.
- **The GUI.**
  - `FrameViewModel` (`gui/star/FrameViewModel.swift:100–118`) and `ImageSequenceViewModel`
    (`:2305`, `:2791`, `:3146`) build each frame's set of available view modes from which
    `.original`-size files exist.
  - `FrameEditImageView.fullResolutionImage` loads the full-size file for the current
    view mode.
  - `PreviewOp` regenerates missing previews from full-size files.
- **`HorizonRefinementOp`** (`:42–44`) uses their existence as "this frame has been
  aligned".
- **The daemon** serves their *previews*
  (`daemon/Sources/stard/handlers/AlignmentHandlers.swift`).

**What to do:**

- **Default (automatic without outliers):** don't write the full-size aligned TIFFs at
  all.
  - Keep writing their previews whenever previews are on (the GUI forces them on).
    `ImageAccessor.save(_:frameIndex:as:atSizes:overwrite:)` already derives every size
    from the in-memory image, so dropping `.original` from `atSizes` is enough.
  - On resume, recompute the merge. The fused merge is ~0.1s of GPU plus the neighbour
    decodes, which costs less than writing and re-reading 2 × 196MB on a slow drive.
- **Outlier and selective modes:** keep writing them, because something reads them back.
  But write them:
  - **uncompressed** (`IMWRITE_TIFF_COMPRESSION`, `COMPRESSION_NONE`), so the reload takes
    `tiffReadDirect`;
  - **without `fsync`** — they are caches. After a crash a renamed-but-unflushed one can
    hold garbage; it fails to decode, and `loadOrCreateAlignedImage` recreates it when its
    load returns nil;
  - **through `IOWork`**.

  The final output keeps its `fsync`.
- **The GUI:**
  - Treat the aligned view modes as available when the frame *can* produce them (its
    homographies exist), not only when the file exists.
  - When the user opens one at full resolution with no file on disk, generate it on
    demand through `loadOrCreateStarAlignedImage` / `loadOrCreateEarthAlignedImage`, save
    it (uncompressed, no fsync), and show it.
  - `PreviewOp` must not assume a full-size original exists for these types.
- **`HorizonRefinementOp`:** switch its "has alignment" test to whether the homographies
  exist.
- **The CI smoke test** (`.github/workflows/cli.yml`) counts the entries in the output
  directory and expects 19. Check whether skipping intermediates changes that count, and
  update the expectation deliberately if it does — do not let it drift.

Leave the format of the final output alone. It is the user's product, and changing it is a
separate decision: LZW saves 0–8% here, at the cost of CPU and slow re-reads.

### Decoding each frame once

- **Within a merge op:** `createAutoProcessedImage` runs the star build and then the earth
  build, and each passes neighbour *filenames* to `ia_align_and_median_merge`, which
  decodes them through `image_cache_load`. The two builds use the same 9 files.
- **Do this:** add a process-wide map of decoded originals keyed by path, behind the C++
  loader closure.
  - Reference-count each entry: a merge op pins what it loaded until it finishes, and any
    concurrent op asking for the same path shares the entry.
  - Its memory is already inside the merge op's reservation, because the op would have
    decoded those frames anyway.
- **Optional, phase 4:** keep a bounded LRU of recently released entries, charged to the
  ledger, so neighbouring frames' merges share decodes too. Adjacent frames share 7 of
  their 8 neighbours.

### The OpenCV QoS patch (decision 3)

- **The change.** In the GCD branch of `cv::parallel_for_`
  (`modules/core/src/parallel.cpp:595–596`), replace
  `dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)` with
  `DISPATCH_APPLY_AUTO`. That constant (macOS 10.13+; star's deployment target is 14)
  asks GCD for worker threads matching the calling thread's configuration, QoS included.
  - It is the only GCD dispatch in the OpenCV star builds; the other matches in the
    source tree are iOS camera code in `videoio`. `grep -rln -e dispatch_apply -e
    dispatch_get_global_queue opencv/opencv/modules` re-confirms it after any version bump.
- **Applying it.** `opencv/build.sh` applies its existing source patches only on a fresh
  clone (the `if [ "$NEED_CLONE" = "1" ]` block). Make this one **idempotent and applied
  on every build**, after the clone-or-reuse step (`grep -q DISPATCH_APPLY_AUTO … || sed
  …`), so cached sources get it too.
  - On Linux and Windows the backend is not GCD: skip the patch there. QoS does not
    exist on those platforms, so the setting maps to widths and memory only.
- **Rebuild.** `bash opencv/build.sh` takes ~6 minutes. Each worktree then needs
  `opencv/include` and `opencv/lib/macos` (both gitignored) copied in or rebuilt.
  - The source it patches is the clone `build.sh` makes at `opencv/opencv`, also
    gitignored. A fresh worktree does not have one; the main checkout's is at
    `/Volumes/rp/git/starry_timelapse_airplane_remover/opencv/opencv` (4.12.0).
- **Verify it with a test, not by reading.** Add a debug C entry point that runs a
  `cv::parallel_for_` and returns the `qos_class_self()` its bodies observed. Call it from
  threads at `.utility` and `.background`, and assert the workers match.

### The setting: "Use of this Mac"

A new `Config` value, provisionally `resourceProfile: ResourceProfile = .full`, with cases
`full`, `balanced`, `light` and `custom`. It changes live, like everything above. Values
below are relative to the machine, with `C = PhysicalCores.count`.

| | Full (default) | Balanced | Light |
|---|---|---|---|
| memory budget (`maxMatMemoryFraction`) | 0.85 | 0.60 | 0.35 |
| CPU gate width | C | C/2 | max(2, C/4) |
| thread QoS (CPU and I/O work, and OpenCV through the patch) | `.userInitiated` | `.utility` | `.background` |
| GPU gate width | 8 | 2 | 1 |
| GPU duty cycle | — | — | ≤ 50% (after each GPU op, hold the gate for as long as the op used the GPU) |
| disk streams per volume | 4 (adaptive in phase 4) | 2 | 1 |
| I/O policy (`setiopolicy_np`, per thread) | default | `IOPOL_UTILITY` | `IOPOL_THROTTLE` |
| pipeline depth cap | 4 × C | 2 × C | C |

- **Light uses `.background`, but watch it.** On this chip background QoS keeps work on
  the second core tier and throttles its I/O. If Light starves under real use (another
  app saturating the machine for minutes), fall back to `.utility` and keep the narrower
  widths. Measure before deciding.
- **Custom** opens every row above as an editable field, pre-filled from the profile it
  was opened from, plus today's advanced fields (the per-op memory multipliers, the
  horizon floor, max keypoint ops). The old "frames at once" number becomes Custom's
  "pipeline depth cap".
- **Migration.** Old configs that set `numberOfFramesToProcessConcurrently` must not stop
  loading. Read the old key into Custom's depth cap, and start every config at Full
  unless it already has a profile (decision 1).
- **Everywhere it appears:**
  - **GUI:** right panel and processing modal — replace the frame field with a
    Full / Balanced / Light control plus "Custom…"; the settings sheet's Memory section
    folds into Custom.
  - **CLI:** add `--use full|balanced|light`; keep `-n` as the Custom depth cap.
  - **Daemon and Kotlin client:** a proto field, mapped in `Mapping.swift`.
- **Live switching.** `FrameGraphBuilder.update(from:)` already runs on every config
  change. Make it apply all gates' `set(max:)`, the QoS of newly started work, the I/O
  policy, the budget fraction and the queue width.
  - In-flight work finishes under the old limits; new work gets the new ones.
  - Lowering the budget below the current ledger just stops admission until it drains
    (`MemoryMonitor` already does this).
- **App Nap.** The GUI's processing activity (`ImageSequenceViewModel.swift`, around
  `:3587`) is `.userInitiated` plus `.idleSystemSleepDisabled`. Under Light, keep the
  sleep assertion but drop to a background activity.

### Bottleneck reporting, then auto-tuning

- **Measure every resource (phase 4).** A `ResourceGovernor` actor samples every ~5s:
  - CPU: star's CPU time, or the CPU gate's busy fraction;
  - GPU: the sum of `gpuEndTime − gpuStartTime` over star's own command buffers;
  - disk: bytes per volume, counted in `IOWork`;
  - memory: footprint against the budget, and the ledger;
  - waiters per gate.
- **Log a line every 30–60s**, and show its last clause in the GUI:

  `resources: CPU 23% (gate 4/18), GPU 4%, /Volumes/rp 212MB/s (gate 4/4, 9 waiting),
  memory 8.6/31.3GB (ledger 22.1GB) — limited by disk /Volumes/rp`

  On the reference setup, that line alone tells the user faster storage beats more
  frames.
- **Auto-tune in Full.** Raise the pipeline depth and per-volume I/O widths while
  throughput (completed ops per minute, weighted by op type) keeps rising and no
  pressure signal fires. Back off on memory pressure or when a step does not help
  (hill-climb, AIMD-style).

## Implementation phases

Each phase ships on its own and is measured on the reference sequence (or a 150–200-frame
range of it) before the next starts. Measure in the merge phase and in phase A
separately: they bottleneck differently.

### Phase 1 — quick wins

1. **Fix the reservations** (merge/outlier static term; split keypoint sky and earth after
   measuring the GPU paths).
   - Acceptance: merge ops reserve 13× on moving runs, the log shows ~12 admitted, and the
     keypoint limit rises accordingly. Unit tests for the multiplier math.
2. **Intermediate TIFFs** as specified above.
   - Acceptance:
     - the default mode writes no full-size aligned TIFFs but still writes their previews;
     - outlier and selective modes write them uncompressed, without fsync, and reload them
       through `tiffReadDirect`;
     - the GUI's aligned view modes still work, generating on demand;
     - resume works;
     - the smoke test is accounted for.
3. **Decode each original once per merge op** (the shared decoded-frame map).
   - Acceptance: one decode per distinct file per op, measured by counting loader calls.
4. **Move saves and decodes off the cooperative pool** into `IOWork` (a single gate at
   first; per volume in phase 2), and the heavy CPU sites listed under "How concurrency
   works today" into `CPUWork`.
   - Acceptance: none of those call sites runs on a cooperative thread. Leave a comment at
     each call site saying why.

Across all of phase 1:

- **Pixels.** The default mode's output must be byte-identical to `e6d04160` on a 20-frame
  range. Phase 1 changes what is written and how often things are decoded, never pixels.
- **Measure** frames per minute in the merge phase and the per-stage times, before and
  after. Expected: most of the ~12s of intermediate saves leaves each frame's latency,
  and roughly two thirds of the merge phase's writes disappear.

### Phase 2 — gates and admission

1. The resizable async gate; `CPUWork` (width and QoS live); `IOWork` per volume (width and
   I/O policy live); the GPU gate made resizable, with the duty-cycle option.
2. A wide queue, with memory as admission.
3. Per-path memory estimates, measured.

Acceptance:

- Unit tests: raising a gate wakes waiters, lowering lets in-flight work finish, and slots
  never leak, including on cancellation.
- Full is at least as fast as phase 1 in both phases.
- `NativeWork`'s fixed `static let` limit and `gpuSlots`' fixed value are gone.

### Phase 3 — the setting, and the OpenCV patch

1. The `ResourceProfile` config value, its live application, and migration.
2. The GUI, CLI and daemon surfaces.
3. The OpenCV patch, with its QoS test.

Acceptance:

- Switching profiles mid-run takes effect within a few seconds.
- Full matches phase 2.
- With another heavy app running (a GPU benchmark, a video export, or a CPU stress loop),
  Balanced and Light measurably reduce star's CPU, GPU and disk use, and improve the
  other app's frame rate or latency. Record the numbers in this document.

### Phase 4 — governor, bottleneck line, auto-tune

The `ResourceGovernor`, the log line and GUI status, auto-tuning in Full. Optionally the
decoded-frame LRU across ops and the elastic budget.

Acceptance:

- The bottleneck line names the right resource on the reference setup (disk in the merge
  phase).
- Auto-tune never ends up slower than fixed Full.
- It backs off on memory pressure.

## Open questions

- **What is using the GPU in the merge phase?** Device utilisation reads ~88% in bursts
  while the fused merges account for ~0.1s each. The per-process AGX counters do not
  report star's compute, and `xctrace record --template 'Metal System Trace'` stalled
  without output from a non-interactive shell. Brian can capture one from Instruments.
  Settle this before choosing Full's GPU width.
- **Discrete GPUs** (the iMac Pro's Vega). Full's GPU width there, and the speed of the
  merge's copy path, are unmeasured.
- **Spinning disks** want 1–2 streams. The adaptive I/O width should find that; until
  phase 4, Balanced's 2 is the safe default for an unknown volume.
- **Phase A** was not profiled in this session beyond its throughput (60–135 keypoint ops
  a minute, ledger-bound at 7). Its real CPU/GPU split on the GPU ports is unknown until
  phase 1's measurements.

## Files to read first

- `GPU_MERGE_BATCHING_FIX.md` — the follow-up section has the merge measurements this
  builds on.
- `StarCore/Sources/StarCore/`:
  - `AsyncOperation.swift`, `FrameGraphBuilder.swift` — the queue, op lifecycle and
    barriers.
  - `MemoryMonitor.swift`, plus `Config.swift`'s multiplier section (around `:455–730` and
    `:1782–1973`).
  - `KeypointLimiter.swift` — the gate pattern to copy.
  - `NativeWork.swift`, `TaskRunner.swift` — the header comment explains the
    cooperative-pool failure mode.
  - `ImageAccessor.swift` (`saveInt`), `ImageCache.swift`.
  - `FrameAlignmentProcessor.swift` (`loadOrCreateAlignedImage`) and
    `FrameAirplaneRemover.swift` (`createAutoProcessedImage`, `finishSelective`,
    `loadOrCreateSubtractionImage`).
- `StarCpp/Sources/StarCppBridge/GPUOps.swift` (`gpuSlots`, `withGPUSlot`).
- `StarCpp/Sources/StarCpp/MatWrapper.cpp` (`tiffReadDirect`, `writeMatAtomically`) and
  `ImageAligner.cpp` (`tryGPUAlignedMerge`, `forEachMergeSource`).
- `opencv/build.sh`, and `opencv/opencv/modules/core/src/parallel.cpp:595`.
- GUI: `gui/star/RightPanel.swift`, `ProcessingModalView.swift`,
  `ProcessingSettingsView.swift`, `FrameViewModel.swift`, `FrameEditImageView.swift`,
  `PreviewOp.swift`.

## Non-goals

- **Changing what any merge computes.** Pixels stay byte-identical.
- **Replacing the op graph or `OperationQueue`.** This changes admission and gating, not
  the graph.
- **Changing the final output's format or compression.** That is a separate decision.
- **Profiling or optimising phase A's algorithms** (Random Walker, RANSAC, the SIFT/AKAZE
  ports) beyond moving them off the cooperative pool.

## Implementation status and findings (2026-10-03, branch `claude/resource-scheduling-design-37393f`)

### What was built

- **Phase 1.** Merge/outlier reservations skip the static-earth term on moving runs (13×, not
  21×). The default mode writes no full-size `.starAligned`/`.earthAligned` TIFFs (previews
  still written); outlier modes write them uncompressed and without fsync
  (`mat_wrapper_write_cache_to`), and the GUI builds them on demand
  (`FrameAirplaneRemover.ensureFullSizeAlignedImage`). `HorizonRefinementOp` and the GUI's
  view-mode availability ask `canProduceAlignedImage` (homographies exist). `DecodedFrameStore`
  decodes each neighbour once per op, behind the C++ loader. Saves and decodes run through
  `IOWork`; the horizon detector's pixel loops, the horizon `scaledY` pass, keypoint YAML
  parsing and the two composite blends run through `NativeWork`.
- **Phase 2.** `ResizableGate` (async and blocking callers share one count), `BlockingGate`
  for the GPU entry points (`GPUOps.setConcurrency`, `setDutyCycle`), `NativeWork`/`CPUWork`
  with live width and QoS, `IOWork` with one gate per volume and a per-thread I/O policy.
  The queue width is `Config.pipelineDepth` (Full: 4×cores). `NativeWork`'s fixed limit and
  `gpuSlots` are gone.
- **Phase 3.** `ResourceProfile` (`Config.resourceProfile`, default Full; old configs load at
  Full and keep their frame count as Custom's depth cap), `ResourceControl.apply` on every
  config change. Surfaces: `--use full|balanced|light` (`-n` opens Custom pre-filled), daemon
  `resource_profile` (field 55, a string), GUI control with a Custom popover and the status
  line, Kotlin settings dialog. OpenCV patch in `opencv/build.sh`, idempotent, every build.
- **Phase 4 (part).** `ResourceGovernor` samples every 5s, logs the "limited by …" line every
  30s, and exposes the last report to the GUI. `AutoTuner` adds disk streams above Full's
  width while they buy throughput (floor is Full itself).

### Findings that change the design

1. **GPU SIFT costs more memory than OpenCV's, not less.** Measured one `ia_find_features`
   per fresh process (`KeypointFootprintMeasurement`; whole-op peak as a multiple of the
   working frame, 33MP and 42MP agreeing to 0.3×):

   | | divisor 1.0 | 1.5 | 2.0 |
   |---|---|---|---|
   | sky, OpenCV | 42.3 | 21.9 | 12.9 |
   | sky, GPU | 53.9 | 29.5 | 17.3 |
   | earth, OpenCV | 28.7 | 16.3 | 10.9 |
   | earth, GPU | 38.8 | 20.9 | 13.8 |

   `useGPUForSIFT` defaults on wherever a GPU exists, so the default sky reservation (42×)
   was below the default path's peak. Estimates are now per detector and per path
   (`Config.effectiveKeypointMemoryMultiplier(for:)`: sky 42/57, earth 31/42 at full
   resolution, OpenCV/GPU). Earth measured higher on this synthetic frame than the earlier
   real-frame figure (18.7–20.5×); the higher one is used. **Decision:** `KeypointLimiter`'s
   memory term now sits on the cheapest path, so it never refuses what the ledger would
   admit; the ledger is the memory gate. Caveat: the frame is synthetic (0 sky keypoints).
2. **The OpenCV QoS premise was half right.** Unpatched, GCD's `dispatch_apply` workers
   already ran at the caller's QoS on macOS 27. What the patch changes is width: a
   `.background` caller gets 6 workers instead of 18. `OpenCVQoSTests` pins both; only
   `testLowQoSUsesFewerWorkersThanNormalQoS` fails without the patch. Light therefore takes
   fewer cores, not only lower-priority ones.
3. **Reference-sequence check (30 frames, moving tripod, debug builds).** Output frames are
   byte-identical to `362c38c0` (0 of 30 differ). Temp dir 17GB → 5.6GB, 150 → 90 TIFFs (the
   60 aligned intermediates). Wall time 5:29 → 6:07 but both are debug builds, run while the
   machine was busy: not a performance result. A release-build before/after on the full
   sequence, with per-stage times, is still owed (acceptance for phases 1–3).
4. A pre-existing test (`UseGPUForMergeLegacyKeyTests`) needed `import StarCppBridge` to compile.
5. `star.pb.swift` was edited by hand (no `protoc`); round-trip tests pass. Regenerate with
   `daemon/regen-proto.sh` when `protoc` is available.

### Not done

- Release-build throughput numbers; the Balanced/Light-versus-another-app measurement
  (phase 3 acceptance); validation that auto-tune beats fixed Full on the USB drive.
- Heavy CPU still on the cooperative pool: the `removeAirplanes` pixel loop and
  `computeRemovalMask` (inside the `FrameAirplaneRemover` actor), Otsu (awaits an async API),
  the outlier/blob orchestration, `HorizonAccumulator.accumulate`, SQLite.
- Per-path *merge* estimates (GPU fused vs CPU) were not split; both still use 13×.
- Pipeline depth is not auto-tuned; the decoded-frame LRU across ops and the elastic memory
  budget (phase 4 options) are not built.
- GUI is compile-verified only (not run). Kotlin compiles and its tests pass.
- Non-English tables carry the English text for the new keys.
- Open questions above (GPU use in the merge phase, discrete GPUs, spinning disks) remain open.
