# Implementation guide: code review fixes (speed, correctness, stability)

**For:** an agent implementing the approved items from
[`CODE_REVIEW_PROPOSAL.md`](CODE_REVIEW_PROPOSAL.md). Read that file first: it holds the
evidence (profiles, crash report, reviewer measurements) behind every item here. This guide
says *what to change, in what order, and how to prove it*.

**Approved scope (2026-10-22):** every item marked **Do** or **A/B** in the proposal. Not in
scope: **Hold** (H5, widening the `outliers.bin` format) and **Later** (C15 feature bugs, K1
Kotlin transport). C15 gets only a `BUGS.md` note (WP-H).

**Line numbers** are at `develop` `93d7a2b6` (0.12.5). Code moves: always re-locate by the
symbol named next to the line.

---

## 0. Ground rules

### 0.1 Branching and commits

* Branch from `develop`, worktree under `.claude/worktrees/<name>`.
* **One work package per branch** (or per PR), in the order below. Inside a package, one
  commit per item ID, message starting with the ID (`S4: alias shares decoded frames`).
* **Never mix an output-identical change with an output-changing one in the same commit.**
  The A/B for an identical change is a byte compare; that only works if nothing else moved.
* End commit messages with the attribution line the session gives you.

### 0.2 Worktree build setup

A fresh worktree lacks gitignored build artifacts. Symlink them from the main checkout
(see project memory `gui-worktree-build`):

```bash
M=/Users/brian/git/nighttime_timelapse_airplane_remover
for d in include lib opencv2.framework; do ln -sfn $M/opencv/$d opencv/$d; done
for d in include lib; do ln -sfn $M/StarDecisionTrees/$d StarDecisionTrees/$d; done
ln -sfn $M/external_binaries/bin external_binaries/bin
ln -sfn $M/gui/videos gui/videos      # gui builds only; this one shows in git status — never commit it
```

Builds:

| what | command | notes |
|---|---|---|
| core + tests | `swift build --package-path StarCore`; `swift test --package-path StarCore --filter <Class>` | |
| C++ bridge tests | `swift test --package-path StarCpp --filter <Class>` | |
| cli (release, for all A/B runs) | `cd cli && swift build -c release` | ~7.5 min cold. `cli/star.xcodeproj` does not link — don't use it |
| daemon | `swift build --package-path daemon`; `swift test --package-path daemon --filter <Class>` | if a new StarCore symbol "is not in scope", run a plain `swift build` first |
| gui | `xcodebuild -project gui/star.xcodeproj -scheme star -configuration Debug build` | `-scheme star`, never `-target Star` |

Copy each release `star` binary aside (`cp cli/.build/release/star /tmp/<x>/star_<tag>`) so
a baseline and a candidate can be run without rebuilding.

### 0.3 Machine safety (read before running anything big)

On 2026-10-22 two concurrent `selective` runs on the dense crop fixture hung WindowServer and
the macOS watchdog ended the user session (proposal, finding 8). Until X1 lands:

* **Never run two dense-field (`a7sii_10_crop16`) runs at once.** One at a time.
* Pass **`-n 3`** (pipeline depth 3 instead of 72) and run under **`nice -n 10`**.
* Run under the watchdog in [Appendix A.3](#a3-guarded-runner); it kills `star` on RSS > 30 GB,
  `memory_pressure -Q` free < 35 %, or swap nearly full. Its PID lookup must use
  `pgrep -P <pid of time>` — matching on the command line finds `/usr/bin/time` instead.
* Brian usually has Photoshop, Lightroom and the Star gui open (tens of GB). Check
  `ps -axo rss=,comm= | sort -rn | head` before a long run.
* This machine is an iMac Pro on mains power: never shorten work "to save battery".

### 0.4 Verification toolkit

* **Identity A/B (output-identical items).** Two fresh copies of the input directory with
  *different names* (temp and output paths derive from the input dir name — project memory
  `cli-behaviour-verification`), baseline binary on one, candidate on the other, then
  [Appendix A.4](#a4-output-comparison). Expect every output TIFF byte-identical.
  * Default path: `test_data/test_a7sii_10` (19 x 4240x2832 JPEG), default flags.
  * Blob pipeline: the same sequence with `-c selective` and with `-c automatic:true`.
  * Anything touching the blob pipeline: run **both sides with `SWIFT_DETERMINISTIC_HASHING=1`**
    until C3 lands, otherwise BUG-001's run-to-run noise hides the comparison.
* **C++ kernel identity.** The `#include`-the-real-`.cpp` differential harness (project memory
  `merge-step-cost-breakdown`): a standalone binary that includes the shipped `.cpp` and a
  renamed copy of the old kernel, diffing outputs. Use an absolute include path (a relative
  one resolves through the `opencv` symlink into the main repo and tests the unmodified file).
* **Speed.** Report CPU-seconds (`/usr/bin/time -l`: user + sys) and per-stage wall time from
  the `transitioning to state` log lines ([Appendix A.2](#a2-stage-timeline)), plus min-of-K
  timings for kernels. End-to-end wall clock on this machine has a ~90 s noise floor (project
  memory `perf-measurement-noise-floor`) — never conclude from one run.
* **GPU-slot breakdown.** [Appendix A.1](#a1-sampler-and-slot-breakdown): `sample` the run and
  sum leaf time inside `withGPUSlot`. Baseline, 12 MP keypoint phase: Metal create/free 22-43 %,
  `getBytes` 13-20 %, `waitUntilCompleted` 0-2 %; merge phase: `memcpy` ~60 %.
* **Output-changing items.** The removal oracle (project memory `removal-validation-oracle`,
  `removal_tools/` on branch `claude/gherkin-removal-validation-40e353`), the homography
  recompute harness and reciprocity check (memories `star-homography-recompute-harness`,
  `homography-reciprocity-check`), horizon reference masks (`HorizonScoringMeasurement`).
* **Dense crop fixture**, regenerated locally (no download), into your scratch directory:

  ```bash
  OUT=<scratch>/crop16; mkdir -p $OUT && for f in test_data/test_a7sii_10/*.jpg; do
    b=$(basename "$f" .jpg)
    magick "$f" -crop 2300x1450+1500+600 +repage -depth 16 -compress lzw "$OUT/$b.tif"
  done
  ```

### 0.5 Do not change

Already measured and decided (see proposal, "Not proposed"): `mergeLoadConcurrency` stays 1;
`mergeStreamingThresholdMB` stays 8192; AKAZE threshold stays 1e-4; keypoint divisor policy;
no `warpAffine`; no OpenCL/T-API; `cv::setNumThreads` cannot cap threads; no GPU for
`FullFrameBlobber`, the DP horizon or TIFF decode; horizon scoring weights/shapes; do not wire
`HomographyHorizonDetector` Pass 2 into production.

---

## WP-0. Baseline (do first, ~1.5 h, mostly waiting)

Record, on current `develop`, with a release binary saved as `star_base`:

1. `test_a7sii_10`, default flags: `/usr/bin/time -l`, stage timeline, GPU-slot breakdown
   (sample every ~15 s), and `shasum` of every output TIFF.
2. Same sequence, `-c selective` and `-c automatic:true`, both with
   `SWIFT_DETERMINISTIC_HASHING=1`: time and output hashes.
3. Dense crop, `-c selective -n 3`, `SWIFT_DETERMINISTIC_HASHING=1`, guarded runner: time,
   peak RSS from the watchdog log, output hashes. Run it **twice, sequentially** and compare
   (this is also the C3/BUG-001 determinism check; if the proposal's finding 7 is already
   filled in, reuse that result instead).

Write the numbers into a `## Baseline` section at the end of this file and commit it. Every
later item quotes its before/after against these.

---

## WP-A. Stability and crashes

Normal-run output must stay byte-identical for every item here (they only change edge-case
behaviour). Verify each with the identity A/B on `test_a7sii_10` default + selective.

### X1 — bound the line connector (first item to land)

*Where:* `StarCore/Sources/StarCore/LinearBlobConnector.swift`, `process(_:)` ~270-380; the
per-seed `taskGroup.addTask` at ~316; `processBlob` ~384; `Blob.absorb` in `Blob.swift:696-730`.

*Change:*
1. Replace the unbounded fan-out (one child per seed, up to `maxBlobsProcessed` = 400) with a
   sliding window: add `K` children, then one more per `await group.next()`. `K` comes from a
   new `Config` property (`linearConnectorSeedConcurrency`, default 4) — remember a new
   property touches seven places (project memory `config-property-removal-surfaces`) and the
   Mirror-driven round-trip test. The results are unioned into a `Set<BlobMapping>`, so
   completion order does not matter.
2. Make `Blob.absorb` update `self.pixels` in place (`self.pixels.update(with:)` /
   `formUnion`) instead of `var updatedPixels = self.pixels; …; self.pixels = updatedPixels`,
   which copies the whole set every call. Keep the size check, the duplicate warning and the
   status-tracker recording behaviour exactly.
3. Measure the outlier op's real peak on the crop after 1-2 (watchdog log, `-l info`
   `op memory [...]` lines with `--log-op-memory`). If it still exceeds the reservation
   (`Config.effectiveOutlierMemoryMultiplier`, `Config.swift:2088`), raise the reservation for
   the op from the measured blob count, or reserve the connector's working set explicitly via
   `MemoryMonitor`. Record the numbers.

*Why identical:* each seed's work reads only shared, read-only state (`data.blobMap`,
`data.blobRefs`, `data.analyzer` dimensions) and returns its own mappings; nothing a seed does
affects another seed. Confirm with the crop A/B under `SWIFT_DETERMINISTIC_HASHING=1`.

*Done when:* crop `selective` is byte-identical to baseline (deterministic hashing), its peak
RSS and CPU-seconds are recorded and lower, and a test covers `absorb` (size, duplicates,
refusal over 65,535).

### C2 — `MemoryMonitor` books grants late and lets new requests jump the queue

*Where:* `StarCore/Sources/StarCore/MemoryMonitor.swift`: fast path ~426-445, slow path
~498-515 (`reservedBytes += bytes` after `withCheckedContinuation`), drain ~880-959
(`waiters = remaining; for waiter in released { waiter.continuation.resume() }`).

*Change:* in the drain, add `reservedBytes += waiter.needed` for every waiter it releases (the
speculative total it already computes is the right number) and remove the post-resume
increment in `reserve`. On the fast path, admit only when `waiters.isEmpty` (the reality-hold
branch already checks this; the plain branch at ~440 does not). Keep `noteSerialAdmission`,
forced-admission and logging behaviour.

*Tests (`MemoryMonitorTests`):* releases and reserves interleaved on the actor must never push
`reservedBytes` over budget; a request arriving while waiters are queued must not be admitted
ahead of them. The reviewer's stripped simulation went over budget in 192/200 runs; make the
test reproduce the old failure first.

### C4 — 16-bit id and size limits

*Where:* `Blob.swift` `outlierGroup(at:withId:…)` ~837 (`UInt16(self.id)`),
`persistentDataArray` ~103-145 and `persistentDataSizeBytes` ~147;
`FrameOutlierProcessor.swift:177` (`currentMaxID + 1`); `BlobBinarySaver.save`
(`UInt16(blobMap.count)`); loader `BlobBinaryLoader.loadMap`.

*Change:*
* Size the array from the pixels actually saved (`pixelsToSave.count`), so a ≥65,535-pixel blob
  no longer leaves trailing zeros that misalign every later blob in `outliers.bin`.
* Replace trapping conversions with checked ones (`UInt16(exactly:)`); when an id or count does
  not fit, log an error and skip that blob (or stop adding groups) instead of trapping.
* Loader: after reading a blob, advance by the count recorded in the file, not by the loaded
  blob's `persistentDataSizeBytes()`.

*Tests:* round-trip a blob of 70,000 pixels followed by a normal blob through saver → loader;
the second blob must come back intact. Ids above 65,535 must not trap.

### C5 — horizon edge-geometry traps

* `FrameHorizonProcessor.swift:935-940`: `for y in bandTop...bandBottom` traps when the
  expected Y is far outside the frame. Clamp `expY` to `0..<h` or `continue` when
  `bandTop > bandBottom`.
* `CombinedHorizonDetector.swift:888`: `(searchTop + derivR)...(searchBot - derivR)` needs
  ≥ 2·derivR+1 rows. Guard and skip the method (return nil) when the band is too narrow.

*Tests:* drive both with an expected horizon far below the frame / a 5-row band.

### C6 — governor dictionary trap on duplicate volume names

*Where:* `ResourceGovernor.swift:244` `Dictionary(uniqueKeysWithValues:)` keyed by volume
name; ids from `IOWork.swift:69-79`.

*Change:* key the snapshot by the gate's id, not its name (or use
`Dictionary(_:uniquingKeysWith: +)`); resolve symlinks (`resolvingSymlinksInPath`) before
computing the volume id in `IOWork`. *Test:* two gates with one name must not trap.

### C7 — force-unwrapped C++ results

*Where:* `StarCpp/Sources/StarCppBridge/ImageAligner.swift:43, 57` (`MatWrapper(ref: r!)`),
plus implicitly unwrapped returns in `createGradientMaskIntoSky`, `ensure16Bits`,
`BufferHolder.toMat`.

*Change:* return optionals; callers fail the frame/op with a logged error (and a `StarWarning`
where the op already reports write failures). No behaviour change on success.

### C9 — cancel lost while `FrameGraphBuilder.build()` is running

*Where:* `FrameGraphBuilder.swift` `build()` (~467-1203, enqueue at ~1201),
`cancelAllOperations` (~1334), `cancelAllOperationsAndWait` (~1359).

*Change:* a `cancelGeneration` counter on the actor, bumped by every cancel. `build()`
captures it on entry and, before `queue.addOperations`, skips the enqueue (reporting through
its completion as cancelled) if it changed. `cancelAllOperationsAndWait` also waits for any
build in progress. Remove the daemon's workaround only if it becomes redundant
(`daemon/Sources/stard/Session.swift:373-375`) — otherwise leave it.

*Test:* start a build on a many-frame harness sequence, cancel while it is suspended, assert
nothing is enqueued.

### C14 — read-modify-write races in `FrameAirplaneRemover`

* `set(cleanMethod:)` (`FrameAirplaneRemover.swift:1663-1680`): move the read-edit-write of
  `pixelReplacementOverrides[frameIndex]` into a single `ConfigManager` method that runs on the
  main actor in one step.
* `startSaveTimerTask` (`:295-310`): clear `saveTimerTask` only if it is still the task that is
  finishing (compare identity).

---

## WP-B. Speed, output-identical

Every item: byte-identical outputs on the identity A/B (default, selective, automatic:true),
plus a before/after number from WP-0. Order is by expected payoff.

### S1 — Metal resource churn and read-back in the GPU pyramids

*Where:* `StarCpp/Sources/StarCppBridge/GPUOps.swift`: `buildSiftPyramidImpl` (~883-1018),
the AKAZE pyramid builder (~1140-1336, a new texture per FED sub-step at ~1293),
`makeFloatTexture` (~1338), `matWrapper(fromFloatTexture:)` (~1352-1364),
`withGPUSlot` (~252). C side: `mat_wrapper_create` (`MatWrapper.cpp:392-399`, clones when
`takeOwnership`).

*Change, in this order (measure after each):*
1. **Texture pool.** A per-backend pool of `.r32Float` `.managed` textures keyed by
   (width, height), checked out for one pyramid build and returned after read-back. Bound its
   total bytes (e.g. 2x one 42 MP SIFT pyramid) and drop it on memory pressure
   (`MemoryMonitor` already exposes pressure). Keep `.managed` + the explicit blit
   `synchronize` on this Vega — `.shared` textures read back as zeros here (doc comment
   ~870-879). Leave a note that Apple Silicon wants `.shared`.
2. **Single-pass read-back.** Add `mat_wrapper_new(width, height, cvType)` in C++ (allocates an
   owned, continuous `cv::Mat`), then `getBytes` straight into `mat_wrapper_data_ptr`. This
   removes the `[Float](repeating: 0, …)` zero-fill and the clone.
3. **Read back outside the slot.** Inside the slot, blit every level into pooled linear
   `MTLBuffer`s (the blit engine de-tiles), commit, wait, release the slot; then copy from the
   buffers into the Mats on the calling thread.

*Identity:* the kernels and bytes are unchanged; prove with the existing `GPUOpsTests` /
`SIFTDetectorTests` / `AKAZEDetectorTests` GPU-vs-reference checks plus the identity A/B.

*Done when:* the slot breakdown shows Metal create/free < 5 % of slot time in the keypoint
phase, the keypoint stage wall time and sys time are down against WP-0, outputs identical.

### S2 — bind merge inputs in place on discrete GPUs

*Where:* `GPUOps.swift` `runMerge` (~726-756) — used by both `medianMergeImpl` (~476) and
`alignedMergeImpl` (~616) — `bindInPlace` (~770-805), `bindByCopy` (~807-841).

*Change:* try `bindInPlace` for the **inputs** on every device; on a discrete GPU keep the
`.managed` output buffer and copy-out exactly as now (shared output is slow over PCIe). Fall
back to `bindByCopy` only when a wrap fails. Pool the managed output buffers by size. Keep the
`inPlaceMerges` / `copiedMerges` counters meaningful (count input binding mode).

*Evidence:* reviewer measured on this Vega that `makeBuffer(bytesNoCopy:)` works (offset, after
CPU writes); 512 MB wrap 0.00-0.08 s vs copy 0.50-0.69 s; GPU read time unchanged. One noisy
2.0 s wrap was seen — time it on the real run, not just in isolation.

*Tests:* `MedianMergeTests`, `CloudAwareMergeTests`, `GPUOpsConcurrencyStressTests` on a
discrete-GPU path (`GPUOps.setDiscreteMergesForTesting` exists for forcing the mode).

### S3 — parallel SIFT CPU tail

*Where:* `StarCpp/Sources/StarCpp/SIFTDetector.cpp`: `buildDoGPyramid` (162-174),
`findScaleSpaceExtrema` (338-420), `detectAndComputeImpl` (579-655).

*Change:*
* DoG: run the per-level `cv::subtract` calls in a `cv::parallel_for_` over levels (or compute
  DoG on the GPU inside S1's command buffer and read it back too — only if S1 is in).
* Extrema scan: split rows `[kImgBorder, rows - kImgBorder)` into contiguous bands; each band
  writes its own `std::vector<cv::KeyPoint>`; concatenate **in band order**. That reproduces the
  serial order exactly, so `removeDuplicatedSorted` and `retainBest` see the same input.
* Update the header comment that calls this "not the hot path" — the profile says otherwise.

*Identity:* differential harness comparing keypoints and descriptors byte-for-byte on real
frames (GPU and CPU pyramid variants), plus the identity A/B.

### S4 — `mat_wrapper_alias` must share, not copy

*Where:* `MatWrapper.cpp:381-386`; `MatWrapperImpl.hpp` `Adopt` constructor (34) and
`canAdopt` (75-80); caller `StarCppBridge/ImageCache.swift:36`.

*Change:* give alias its own constructor that always shares when `m.u` is set, the Mat is
continuous and not a submatrix — no refcount requirement. Keep `canAdopt`'s refcount rule for
`wrap()` only (that is what it protects). Update the comments.

*Test (`MatWrapperTests`):* two aliases of a live wrapper share one buffer (same data pointer)
and the accounting (`totalBytes`) counts each wrapper as today.

### S5 — pin the static earth merge's neighbours

*Where:* `FrameAlignmentProcessor.swift` `pinNeighborDecodes` (137-147); static merge
(~979-989).

*Change:* when the op will run the 16-neighbour static merge, also pin the
`staticNeighborFrames` filenames. *Test (`DecodedFrameStoreTests`):* the store's
`decodeCount` for one static op equals the number of distinct files.

### S6 — repeated decodes of originals

1. *Measure first:* log, once per run at `-l info`, `DecodedFrameStore.decodeCount`, the
   `ImageCache` hit/miss counters, and decodes per frame. Record for `test_a7sii_10` (JPEG) and
   the crop (LZW TIFF) in the Baseline section.
2. If decodes per frame are above ~2: route base-frame loads of originals
   (`ImageAccessor.loadInt`, ~235-260, `.original` type) through `DecodedFrameStore` under the
   calling op's pin, so a frame held for a merge is not decoded again by the same op. Do not
   add an unpinned LRU (the store deliberately holds nothing it cannot account for).
3. Optional, behind a config flag defaulting off: an "uncompressed working copy" of compressed
   originals in the temp dir, so later reads take the existing direct-read fast path
   (`mat_wrapper_tiff_is_fast_readable`). Only if step 1 shows decode CPU is material.

### S7 — horizon detector waste

* `CombinedHorizonDetector.runDP` (417-426) calls `pib_dp_horizon_mask` for 36 parameter
  combinations; each call recomputes grey / `ensure8U` / Sobel / Canny
  (`PixelatedImageBridge.cpp:771-805`). Split the C function into "prepare" (returns the
  preprocessed mats) and "solve(params)"; call prepare once.
* `runOtsu` (389-403) / `runDP` (446-461): drop `thresholdToBinary` + the second
  `extractHorizonY` (`extractHorizonY(thresholdToBinary(m)) == extractHorizonY(m)`); route
  `runOtsu`'s full-res tail through `NativeWork`.
* Random Walker brushes (~1161, `selfScore` ~1521): score each brush from its `resultY`
  (a value in `[0, H)` maps to itself, anything else to nil) and build the full-res mask only
  for the winner.
* `extractHorizonY` scans column-by-column on full-res masks; scan row-by-row.
* `pib_ground_only` / `pib_sky_only` / `pib_filter_connected_components`
  (`PixelatedImageBridge.cpp:189`): replace the per-pixel `std::set` lookup with a per-label
  lookup table.
* `ia_accumulate_one_horizon_mask` (`ImageAligner.cpp:1315-1335`): accumulate in place
  (`cv::add(accum, binary, accum, noArray(), CV_32S)`) instead of cloning the 168 MB total per
  frame; call it via `NativeWork` from `HorizonAccumulator.accumulate`.

*Identity:* `CombinedHorizonDetectorTests`, `HorizonTests`, merged-horizon masks byte-identical
on the identity A/B (keep `--keep-temp-files` and compare `star_temp_*/` masks too).

### S8 — moving-sequence horizon scaling

* `FrameHorizonProcessor.nearestReferenceMasks` (597-613) stats every frame of the sequence,
  three times per frame. List `horizonReference/` once, map file names → frame indices, cache
  on the processor's shared state, invalidate when a reference is saved.
* Brightness refinement (`:951-952`) allocates two `[Double]` per pixel: hoist them out of the
  loop (reviewer bench: 2.9 s → 0.88 s, identical). Run the whole refinement through
  `NativeWork`.

*Identity:* a moving-sequence run with painted references (`FrameHorizonProcessorTests`
fixtures) produces identical merged masks.

### S9 — logging

*Where:* `logging/Sources/logging/Log.swift` (`logInternal` ~902-957, drain loop ~1028-1035).

*Change:*
1. Make every `Log.v/d/i/w/e` message parameter `@autoclosure @escaping () -> String?` and
   evaluate it only after the level check. This turns `Log.i("…\(await x)…")` call sites into
   compile errors — fix each by computing the value first, behind a new public
   `Log.isEnabled(_ level:)` check (today `minimumLogLevel` is private, `Log.swift:145`) where
   it costs an actor hop
   (`BlobLineTrim.swift:193, 196`, `LinearBlobConnector.swift:544, 553`, and whatever else the
   compiler finds).
2. Replace "one `Task` per line + three actor hops" with a synchronous, lock-protected append
   of `(time, level, message, file, line)` to the gremlin's queue, preserving call order.
3. Replace the 1 ms polling drain with a continuation-woken drain. `finishLogging()` must still
   flush everything; crash handlers must still be able to flush synchronously.

*Tests:* order preserved across threads; filtered messages' autoclosures never run; existing
logging tests pass. Check the cli's console output and the gui/daemon diagnostic log still
look the same.

### S10 — `ResizableGate` fairness

*Where:* `StarCore/Sources/StarCore/ResizableGate.swift` (`acquireBlocking` 64-69, `acquire`
~73-100, `release` ~119-128, `grantLocked` ~138-145).

*Change:* one FIFO for both waiter kinds: a blocking caller parks an entry with its own
`NSCondition` (or semaphore) in the same `waiters` array; `grantLocked` grants strictly in
arrival order and signals the blocking entry it chose. Keep cancellation semantics as they are
(H5 is on hold). *Tests (`ResizableGateTests`):* a blocking acquirer queued before async
acquirers gets the slot first; no lost wakeups under stress.

### S11 — blob pipeline (selective / automatic:true)

1. **Remove `LinearBlobExtender`** from the processors' step lists
   (`Mild/Strong/Stronger/ExcessiveBlobProcessor.swift`; keep the enum case for configs and
   `CustomBlobProcessor` compatibility). It cannot absorb anything (`iterationBlob` starts nil
   and is only set inside a branch that requires it non-nil, `LinearBlobExtender.swift:204,
   308, 338`), so outputs are identical. Note in the source why.
2. **`borderBrightness` decodes the original per group** (`OutlierGroupFeature.swift:663-676`,
   weak cache). Load the original once per frame in the classification entry point and pass it
   down (or pin it in `DecodedFrameStore` for the duration). Identical.
3. **`FullFrameBlobber` rewrite** (`FullFrameBlobber.swift`): replace the
   `PixelStatusTracker` actor, `[[SortablePixel?]]` and per-pixel `await blob.add` with
   synchronous row-major arrays (`[UInt16]` intensities, an `[Int32]` status/blob-id map) and
   per-blob pixel lists; build the `Blob` actors at the end, in the same id order. Keep:
   the brightness sort order (a **stable** counting sort on the 16-bit value reproduces Swift's
   current order — verify, don't assume), the neighbour order, the duplicate pushes in
   `expand` (the contrast threshold depends on the blob size at the moment a neighbour is
   checked), `startingBlobID`, the `bounds` handling. Drop the unused `originalImage`
   (`AbstractBlobProcessor.swift:267` load included). *Test (`FullFrameBlobberTests`):* old vs
   new blobber on several real subtraction images → identical blobs (ids, pixel sets).
4. **`HoughLineMatrixBlobConnector`** (`:204-217`, `:340-408`): use the synchronous
   `Line.iterate` with local accumulators instead of per-pixel async closures and actor hops;
   split the image into tiles once (it is split twice from the same image); skip the
   Hough transform for tiles with no blob pixels; don't compute `pixelScore` where only
   `intensityScore` is read. Identical.

### S12 — smaller identical wins

* `computeRemovalMask` (`FrameAirplaneRemover.swift:1299-1410`): put `maskX` innermost (or
  iterate rows of the mask), and keep alpha as the mask's `UInt8` level or index instead of a
  337 MB `[Double]` at 42 MP. The final blend must see the same alpha values.
* Blocking YAML I/O on the cooperative pool: `OCVFeatureSet.load` in task-group children
  (`AlignmentValidationOp.swift:200-204`) and `results.write` (`FrameAlignmentProcessor.swift:
  700`) → `NativeWork.run`.
* AKAZE port: compute orientation after `runByPixelsMask` + `retainBest`
  (`AKAZEDetector.cpp:801-805`); neither filter reads the angle.
* `buffer_holder_to_mat` clones (`BufferHolder.cpp:71-72`) although `ImageBuffer.image` says it
  shares; share when the holder's lifetime allows, else fix the comment.

### S13 — GPU utilisation metric

*Where:* `ResourceGovernor.swift:262` (`gpuPercent`), `GPUOps.record(busyNanoseconds:)`.

*Change:* report two numbers: slot occupancy (Δbusy / window / gate width) and device-busy time
from `MTLCommandBuffer.gpuStartTime`/`gpuEndTime` accumulated per command buffer. "Limited by
GPU" should key off device-busy, not slot occupancy. Diagnostics only — no scheduling change.

---

## WP-C. Bugs whose fix changes output only in the broken case

### C1 — partial-range static horizon vote

*Where:* `HorizonAccumulator.swift` (`finalize`, `total = frameCount` at 77; `accumulate`),
`ImageAligner.cpp` `ia_accumulate_from_files` (~1336-1360, skips missing files) and
`ia_finalize_horizon_accumulation` (~1366-1374), `FrameGraphBuilder.swift:703`, the reference
save in `FrameHorizonProcessor.swift` (~468).

*Change:*
* Count masks actually folded in (in-memory adds + files that actually loaded) and vote
  against that count; return the count from the C++ accumulate-from-files call.
* Mark disk-loaded frames as accumulated.
* If an accumulate fails, keep the previous `accum` (don't replace it with nil).
* Refuse to write `horizonReference/reference.tiff` (and refuse to hard-link the merged mask)
  when the result is all ground or all sky; log a warning instead.

*Tests:* accumulator with `frameCount` 1000 and 108 masks votes against 108; an all-ground
result is not saved as a reference. *Verify:* `star -L 9` on a fresh copy of `test_a7sii_10`
now produces the same merged horizon as a full run's for those frames (or a sane one), and no
all-black reference.

### C8 — stale horizon caches

* `StarAlignedHorizonMask.swift:160`: replace the 1-in-~643-pixels digest with a hash of the
  per-column horizon Y; call `invalidateAll` (138) when a reference is saved.
* `ReferenceHorizonStats.swift:218`: key the process-wide cache by (sequence path, frame index,
  `referenceHorizonNeighborhoodSize`, bucket count); clear it when a sequence closes.

*Tests:* a 50x10 px repaint changes the key; two sequences with references at the same indices
get their own statistics.

---

## WP-D. Output-changing items (each gated on a measured A/B)

Land each separately. For each, record before/after on the named measures in the Baseline
section and in the commit message. If an item makes the oracle worse, stop and report rather
than tuning thresholds.

### C3 — make the blob pipeline deterministic (BUG-001)

* `LinearBlobConnector.process` (~286-295): sort seeds by (size desc, id asc) before the 400
  cut.
* `processBlob` (~404): absorb the neighbour cloud in ascending id order (sort the `Set<Blob>`
  into an array) so which pixels fit under the 65,535 cap is fixed.
* `AbstractBlobProcessor.compactBlobIds` (167-176): renumber in ascending old-id order.
* `BlobLineTrim` (~126): assign new ids in a deterministic order, not task-completion order.
* Line fitting from `Array(self.pixels)` (`Blob.swift:239`, `OutlierGroup.swift:104`): sort the
  pixels (y, x) before summing.

*Verify:* the crop `selective` run twice **without** deterministic hashing → identical outputs;
removal oracle on `a7sii_10` (selective and automatic:true) no worse than baseline. Remove
BUG-001 from `BUGS.md` if both hold (BUGS.md lives on branch
`claude/gherkin-removal-validation-40e353`; coordinate if it has not merged).

### S14 — bound the neighbour cloud (BUG-003 proper)

`neighborCloud` (`BlobAnalyzer.swift:250-276`) is a transitive closure; in a dense field it is
most of the frame, rebuilt for each seed. Options, in order of preference:
1. Non-transitive cloud: blobs within `scanSize` of the *seed's* bounding box, expanded at most
   N hops (N from config, default 2).
2. Compute connected components of the "within scanSize" graph once per frame, process each
   component once (skip seeds whose component is done).

*Measure:* crop `selective` wall/CPU/peak RSS (BUG-003: 25-35 min), BUG-001 collateral on the
crop, removal oracle on `a7sii_10`. If `.linear*` outlier features shift, flag the trees for
retraining rather than tuning.

### C10 — apply the sky mask before the SIFT keypoint cap

*Where:* `SIFTDetector.cpp:634-645` (port); `ImageAligner.cpp:1614-1615` (`cv::SIFT`
fallback); premise comment at `ImageAligner.cpp:1490-1494`.

*Change:* port — rescale, then `runByPixelsMask`, then `retainBest`, then descriptors; also
skip the extremum scan outside the mask (S3's bands can test a downscaled mask row). Fallback
— `detect` with the mask and no cap, `retainBest`, then `compute`. Fix the comment.

*Measure:* sky keypoint counts on moonlit/twilight frames (reviewer: a9-1 frame 119 returned
1809 with 3529 in-mask available); homography recompute harness + reciprocity check; star-
centroid truth recipe from memory `moonlit-horizon-step-sky-keypoints`.

### C11 — GPU warp precision

*Where:* `GPUOps.swift:383, 613` (float inverse homography), `warp_tap` (~1412-1437), library
compile options (~291).

*Change:* compute per-row projection terms in double on the CPU (or carry the projection in
two-float arithmetic) so the sample positions match OpenCV's `remapBilinear` fixed-point
steps; compile the warp kernels without fast math. *Test:* a full-size (42 MP-wide) GPU-vs-CPU
warp test counting pixels on a different 1/32-px step — target 0 (baseline 0.72 % at 6000 px).

### C12 — centre the removal halo

`computeRemovalMask` offsets by `Int(removeMask.radius)` while the mask's centre is
`Int(radius + 1)` (`RemoveMask.swift:29`, `FrameAirplaneRemover.swift:1330`). Offset by
`removeMask.center`. *Measure:* removal oracle (trail contrast, star flux) no worse.

### C13 — merges must not drop blobs

`combine()` (`HoughLineMatrixBlobConnector.swift:297-304`, used by both connectors) ignores
`absorb`'s refusal; the refused blobs were already removed from the map. Return the refused
blobs and put them back in the map. *Measure:* removal oracle; count of blobs before/after.

### S15 — Random Walker cost

*Where:* `RandomWalkerHorizon.cpp` (`gaussSeidelWithData` 202-258, solves 524-555, colour
conversion before downscale 337-353), brush loop in `CombinedHorizonDetector` (~1161).

*Change:* (a) do the crop / LAB / bilateral / median / Sobel once per frame on the largest
brush's ROI; (b) downscale before LAB conversion; (c) replace plain Gauss-Seidel with SOR
(ω ≈ 1.8, tune on fixtures) or a red-black parallel sweep. Each is a separate commit.
*Measure:* horizon error against reference masks (`HorizonScoringMeasurement`,
`CombinedConfidenceMeasurement`) and CPU-s per frame; reject any step that worsens the error.

### S16 — CPU coverage warp over border strips only

`ImageAligner.cpp:3966-3971`: compute the certainly-covered interior from H in double (frame
corners inset by 2 px), warp the coverage probe only over the border strips. OpenCV rounds per
block, so identity is not guaranteed: run the identity A/B with `--no-use-gpu` and accept only
if outputs are identical or differences are explained and oracle-neutral.

---

## WP-E. Daemon (`daemon/Sources/stard`)

Tests go in `daemon/Tests/` next to the existing `SessionCloseTests`, `DispatcherTests`,
`ExportSequenceTests`, `StdioTransportTests`, `PreviewGenerationTests`.

* **D1** `handlers/ExportHandlers.swift:35-94`, `Session.swift:750-821`: check
  `Task.isCancelled` before each `group.addTask` and at the top of `renderNow`; `renderNow`
  returns false when the session is closed; in `waitForSave`, `do { try await Task.sleep… }
  catch { return false }`; end the forwarding loop only on the render's own "done" sentinel
  (tag it, e.g. a unique state string, instead of breaking on any `.sequenceState`).
  *Test:* cancel mid-render → no new renders start, no busy loop (count `savingState` calls).
* **D2** `handlers/PreviewFiles.swift:84-98` `FullSizeGate`: on release hand the slot directly
  to the next waiter (keep `busy == true`); waiters use `withTaskCancellationHandler` to remove
  themselves; re-check cancellation before decoding. *Test:* at most one full-size job at once;
  a cancelled waiter never runs.
* **D3** `Stard.swift:142-143`: feed every decoded envelope into one `AsyncStream` consumed by
  a single task that dispatches in order (requests still run concurrently once dispatched); or
  have `Dispatcher` remember cancel ids that arrive before their request.
  *Test (`DispatcherTests`):* cancel delivered first still cancels.
* **D4** ignore `SIGPIPE` at startup; `StdioTransport.swift:79-85` write with
  `try outHandle.write(contentsOf:)` and treat failure as EOF; on stdin EOF run the same
  session-close path as `Shutdown` before exiting.
* **D5** `handlers/FrameHandlers.swift:82-117`: cache the label image per frame keyed by the
  outlier-groups version; write via temp file + rename.
* **D6** register `configManager.onUpdate` once per builder/session: in
  `FrameGraphBuilder.set(configManager:)` (`FrameGraphBuilder.swift:91-102`) skip
  re-registration for the same manager (or return a token and remove the old callback); apply
  to cli, gui and daemon callers.
* **D7** `handlers/OutlierHandlers.swift:164, 223, 363`: `UInt16(exactly:)` with an error
  response; cap the frame length in `readFrame` (e.g. 256 MB) and treat larger as a protocol
  error.

## WP-F. macOS gui (`gui/star`)

No automated UI tests here; use unit tests where the logic can be split off the view model,
and the snapshot recipe in memory `gui-view-snapshot`. Build with `-scheme star`.

* **G1** `ViewModel.swift:403-414` `unloadSequence()`: call the sequence view model's
  `stopProcessing()` (`ImageSequenceViewModel.swift:2524`), `stopVideo()` (`:3306`) and
  `disable()` (`:1907`, ends the App Nap activity) before dropping it.
* **G2** `ImageSequenceLoadingView.swift:66-68`: keep the load task and cancel it on Cancel;
  check `Task.isCancelled` before assigning `imageSequence`. Move
  `frameGraphBuilder.set(configManager:)` (`ImageSequenceViewModel.swift:2116`) from load to the
  start of processing.
* **G3** `ImageSequenceViewModel.swift:2972-2980` `processFrames`: route re-process actions
  through the cancel-and-wait path `updateSettingsAndProcess` uses (or disable those menu
  items while `isProcessingFrames`); never clear `isProcessingFrames` for a run that was not
  the current generation.
* **G4** main-thread / per-tick work:
  * grid slider (`GridView.swift:36-38` → `FrameViewModel.swift:543-560`): extract each frame's
    per-column horizon once, resample in memory; refresh on drag end;
  * sequence open (`FrameViewModel.swift:114-140`, `ImageSequenceViewModel.swift:2176, 2772`):
    set `.frame` once; do the file-existence checks off the main actor; build outlier views and
    overlays only for the visible frame;
  * alignment chart (`AlignmentWindowView.swift:123-124, 353-368, 678-720`): compute points once
    per data change with stable ids;
  * `GridLeftPanel.swift:90-101` `visibleModes`: keep a per-sequence set of available modes,
    updated when images are saved.
* **G5** `InitialView.swift:161-180`: put the `do/catch` inside the `Task`;
  `UserPreferences.swift:216-272`: atomic write (temp + rename, `Data.write(options: .atomic)`),
  and never save over a file that failed to decode (the Kotlin client shares it).

## WP-G. Hardening

* **H1** write feature YAMLs (`OCVFeatureSet.cpp:104-112`) and `artifact_inputs.json`
  (`ArtifactInputs.swift:507`) via temp + rename; at run start delete `*.tmp.<pid>-*` image
  temp files (`MatWrapper.cpp:462-466` naming) under the run's temp and output dirs.
* **H2** `ShellOut.swift:19-37`: read stdout and stderr concurrently (readabilityHandler or two
  reader threads) before/while waiting for exit.
* **H3** `HomographyDatabase.swift:130-135`: on `sqlite3_open` failure close and clear the
  handle so the next call retries; set `sqlite3_busy_timeout`.
* **H4** `logging/…/UpdatableLog.swift:168-213`, `UpdatableProgressMonitor.swift`: build all
  rows, draw once, throttle to ~4 Hz, cap retained error rows.

## WP-H. Backlog notes (no code)

Add to `BUGS.md` (or to this file's end if `BUGS.md` has not merged) under one entry,
"Decision-tree features computed incorrectly — fix only with retraining":
`OutlierGroup.swift:779/801` (far end measured from the wrong intersection),
`Blob.intensity()` always ~0 (`Blob.swift:624`), `pixelBorderAmount` counts diagonals only
(`OutlierGroupFeature.swift:650`), Hough lines scored on the blob-id image
(`HoughLineMatrixBlobConnector.swift:204-211`). Also note K1 (Kotlin `StdioConnection` close
race, no frame-length cap) and H5 (cancel over-grant) as known, deferred.

---

## Findings made while implementing (not in the proposal)

* **The matrix Hough blob connector does nothing in the shipped pipeline.** All four presets pass
  `overlapPercent: 20` to `.houghLineMatrixBlobConnector`, but `mat_wrapper_split`
  (`MatWrapper.cpp`) treats it as a *fraction* (`step = tile * (1 - overlap)`), so a value of 20
  gives a step <= 0 and zero tiles, and the step maps nothing. Measured with a 400x300 image:
  0.2 gives tiles, 20 gives none. Fixing it (20 -> 0.2, or dividing by 100 in the connector)
  re-enables a step that has not run since the C++ port and changes outputs, so it was **not**
  changed; it needs its own A/B and probably the removal oracle. The S11 Hough speedups are
  identity-tested with a fractional overlap and are real, but cost nothing today.

## Appendix A — scripts

These were used for the review; paths are placeholders.

### A.1 Sampler and slot breakdown

```bash
# sample a running star every ~15 s into $OUT/sample_N.txt
i=0; while kill -0 $PID 2>/dev/null; do
  sample $PID 10 -mayDie -file $OUT/sample_$i.txt >/dev/null 2>&1; i=$((i+1)); sleep 5; done
```

```python
# inslot.py sample_*.txt — share of time inside withGPUSlot by leaf/ancestor
import sys, re, collections
keys = ['IOAccelResourceCreate','ioAccelResourceFinalize','getBytes','waitUntilCompleted',
        '_platform_bzero','_platform_memmove','replaceRegion']
for f in sys.argv[1:]:
    stack=[]; tot=collections.Counter()
    for ln in open(f, errors='replace'):
        m = re.match(r'^(\s*[+!:| ]*)(\d+)\s+(.*)$', ln.rstrip('\n'))
        if not m: continue
        depth, n, name = len(m.group(1)), int(m.group(2)), m.group(3)
        while stack and stack[-1][0] >= depth: stack.pop()
        in_slot = any('withGPUSlot' in s[1] for s in stack)
        seen = {k for k in keys if any(k in s[1] for s in stack)}
        stack.append((depth, name))
        if 'withGPUSlot' in name and not in_slot: tot['SLOT'] += n
        if in_slot:
            for k in keys:
                if k in name and k not in seen: tot[k] += n
    if tot['SLOT']:
        print(f, 'slot', tot['SLOT'], ' '.join(f"{k}={100*tot[k]/tot['SLOT']:.0f}%" for k in keys if tot[k]))
```

`.LGLOOPgas_1` / `icv_l9_ownsCopy_8u` is IPP's Mat copy; its stacks are truncated (`???`).

### A.2 Stage timeline

```bash
grep "transitioning to state" star.log | awk '{print $1, $NF}' \
 | awk '{s[$2]=s[$2]?s[$2]:$1; e[$2]=$1; c[$2]++} END {for (k in s) print s[k], e[k], c[k], k}' | sort
```

### A.3 Guarded runner

```bash
#!/bin/bash
# run_guarded.sh <star> <input-dir> <out-dir> <logdir> [star args...]
STAR=$1; IN=$2; OUTD=$3; LOG=$4; shift 4; mkdir -p "$LOG"
SWIFT_DETERMINISTIC_HASHING=${SWIFT_DETERMINISTIC_HASHING:-1} nice -n 10 \
  /usr/bin/time -l "$STAR" -l info -n 3 "$@" "$IN" "$OUTD" > "$LOG/star.log" 2> "$LOG/time.txt" &
TPID=$!; sleep 3
PID=$(pgrep -P $TPID | head -1)            # the star child of /usr/bin/time
ps -o command= -p $PID | grep -q star || { echo "no star child"; kill $TPID; exit 1; }
while kill -0 $PID 2>/dev/null; do
  RSS=$(ps -o rss= -p $PID | tr -d ' ')
  FREE=$(memory_pressure -Q | awk -F': ' '/free percentage/ {gsub("%","",$2); print $2}')
  SWAP=$(sysctl -n vm.swapusage | awk '{gsub("M","",$6); print int($6)}')
  echo "$(date +%T) rss_kb=$RSS free_pct=$FREE swap_used_mb=$SWAP" >> "$LOG/watch.txt"
  if [ "$RSS" -gt $((30*1024*1024)) ] || [ "$FREE" -lt 35 ] || [ "$SWAP" -gt 3700 ]; then
    echo "WATCHDOG KILL $(date +%T)" >> "$LOG/watch.txt"; kill -TERM $PID; sleep 5; kill -KILL $PID; fi
  sleep 10
done
wait $TPID; echo "exit $?" >> "$LOG/watch.txt"
```

Swap on this machine is only 4 GB; adjust the swap threshold if `vm.swapusage` total differs.

### A.4 Output comparison

```bash
# compare_runs.sh <outA> <outB>
A=$1; B=$2; same=0; diff=0
for f in $(cd "$A" && find . -name '*.tif*' | sort); do
  if cmp -s "$A/$f" "$B/$f"; then same=$((same+1))
  else diff=$((diff+1)); echo "$f AE=$(magick compare -metric AE "$A/$f" "$B/$f" null: 2>&1)"; fi
done
echo "identical $same, differ $diff"
```

Outputs are LZW 16-bit TIFFs, so `cmp` only says same/different; `magick compare -metric AE`
counts differing pixels. Also compare each output against its input: an output identical to
its input means that frame was never processed.

---

## Baseline

*(Partly filled in by WP-0; recorded 2026-10-22 on `develop` 0.12.5. The machine was shared with
another agent's runs, so wall times are noisy.)*

| run (`star -l info -n 3`, nice 10) | wall | user | sys | max RSS |
|---|---|---|---|---|
| `test_a7sii_10` default, baseline binary | 191 s | 473 s | 324 s | 10.7 GB |
| same, after WP-A (`star_wpa`) | 158 s | 465 s | 329 s | 10.7 GB |

WP-A identity A/B (default flags, 19 output JPEGs): **all 19 byte-identical** to baseline.
Outputs are JPEGs (the input format), so compare with `shasum`, not TIFF tools.

**Not yet done:** `selective` / `automatic:true` baselines, the dense-crop baseline and A/B (X1
step 3 measurements), GPU-slot breakdown, S6 decode counts. The crop runs hang the display if
mishandled; the GPU tests and `star` runs also hung WindowServer once on 2026-10-22 (logout at
18:57 and 19:11), so run GPU suites and star runs strictly one at a time.
