# Code review: speed and correctness proposal

Status: **approved 2026-10-22** — every item marked **Do** or **A/B**; **Hold** and
**Later** items are out of scope. The work plan is
[`CODE_REVIEW_IMPLEMENTATION_GUIDE.md`](CODE_REVIEW_IMPLEMENTATION_GUIDE.md); this file keeps
the evidence.

Base: `develop` at `93d7a2b6` (0.12.5).

## How this was produced

* **Static review** of StarCore, StarCpp, cli, daemon and the macOS gui, split five ways
  (blob/outlier pipeline, alignment/merge/GPU, horizon, orchestration/memory/logging,
  daemon+gui). Every item below that is marked *read* was re-checked against the code by me
  after the reviewer reported it. The Kotlin client got only a quick look at its transport.
* **Profiled runs on this Mac** (release cli, `sample` every ~15 s, `/usr/bin/time -l`):
  * `test_data/test_a7sii_10`, 19 x 4240x2832 JPEG, default settings (`automatic:false`,
    `strong`, static, all three GPU toggles on): **135.8 s wall, 550 s user + 285 s sys,
    33.7 GB peak RSS**.
  * The `a7sii_10_crop16` fixture from the open `BUGS.md` (regenerated locally with the
    documented `magick -crop 2300x1450+1500+600 -depth 16 -compress lzw`), `selective`, run
    twice concurrently with `SWIFT_DETERMINISTIC_HASHING=1` to test BUG-001. Results in
    [Measured findings](#measured-findings).
* Reviewers also ran small standalone harnesses against the vendored OpenCV and this Vega 64
  (sources in the session scratchpad; the guide will say which ones to recreate).

Markers used below: **measured** = timed or profiled; **read** = established by reading the
code and its call sites; **identical** = output must be byte-identical before/after;
**changes output** = needs an A/B with the removal oracle / homography harnesses, and some
need decision-tree retraining.

---

## Measured findings

These shaped the priorities, so they come first.

1. **On the default path the CPU is mostly idle; the critical path is keypoints.** Timeline of
   the 12 MP run: horizon 27 s, keypoints **65 s**, alignment validation 5 s, merges 32 s. While
   keypoints ran, the governor logged `CPU 16% (gate 14/18), GPU 100% … limited by GPU`.
2. **"GPU 100%" is not the GPU.** Breaking down the time spent *inside* `withGPUSlot` during
   keypoints: Metal texture create/free (`IOAccelResourceCreate` / `ioAccelResourceFinalize`,
   i.e. kernel calls) **22-43%**, CPU-side texture de-tiling in `getBytes` **13-20%**, zero-fill
   **3-5%**, and actually waiting for the GPU (`waitUntilCompleted`) **0-2%**. In the merge
   phase, CPU `memcpy` into freshly allocated Metal buffers is **~60%** of slot time and
   `memmove` is 78% of all busy CPU in that window. The 285 s of **sys** time fits this: page
   faults and wiring for multi-GB Metal allocations made and freed per call.
3. **The CPU half of GPU SIFT is now the SIFT hot spot**, and it is single-threaded per frame:
   DoG `cv::subtract` 6.7% of all busy samples, the extremum scan ~7%, `Mat::at` in refinement
   ~3%. The file header still says "none of this is the hot path".
4. **Horizon detection**: the Random Walker Gauss-Seidel solver was 31% of busy CPU in the
   horizon window (single-threaded, up to 300 iterations), the IPP bilateral filter 13%.
5. **BUG-003 root cause confirmed by profile.** In `selective` on the dense crop, the outlier
   stage is `LinearBlobConnector.processBlob` → `Blob.line` → Hough voting
   (`HoughLineFinder.lineData`, `kht::voting`, `StandardLine.distanceTo`) — ~100% of the
   attributable outlier-stage samples. RSS reached 18 GB on 2300x1450 frames.
6. **Repeated decodes of compressed originals**: on the 16-bit LZW crop, `LZWDecode` under
   `ImageCache.loadImage` (the weak Swift cache) cost ~13.5 CPU-s in two 10 s windows, roughly
   six decodes per frame.
7. **BUG-001 determinism test**: *(pending — the first attempt was lost to the session crash in
   finding 8; restarted one run at a time with `-n 3`, `nice 10` and a memory watchdog; result
   to be filled in before this goes to the guide)*.
8. **Two concurrent dense-field `selective` runs took down the macOS user session.** At 15:52
   WindowServer's main thread sat 40 s inside the AMD driver (`IOAcceleratorFamily2` /
   `AMDRadeonX5000`) and the userspace watchdog killed it (`/Library/Logs/DiagnosticReports/
   WindowServer_2026-10-22-155442_Garth.userspace_watchdog_timeout.spin`). In that report
   **85 threads in other processes** (WindowServer helpers, mds, diskarbitrationd, Chrome, the
   open Star.app) were blocked on kernel turnstiles held by the two `star` processes. Both
   were in the CPU-only line-connector stage (no GPU frames on their stacks), 38 threads
   each, and the load average reached 148. `/usr/bin/time` recorded max RSS of 54 GB and
   15 GB on 2300x1450 frames; one run grew ~1 GB/min for 36 minutes, and its log went silent
   for those 36 minutes while the process kept running. Most likely mechanism (not proven):
   the connector's unbounded seed tasks churning large allocations (`absorb` copies, per-seed
   Hough accumulators) on the cooperative pool, outside the CPU gate and invisible to
   `MemoryMonitor`, and contending global kernel VM locks. See X1.

Note: the default `automatic:false` mode does not run the blob pipeline at all, so the S-B
items below only speed up `selective` and `automatic:true`.

---

## Summary table

Recommendation key: **Do** = include in the guide; **A/B** = include, gated on a measured
A/B; **Hold** = needs a decision from you; **Later** = backlog note only.

### Stability

| ID | What | Effect | Evidence | Rec |
|---|---|---|---|---|
| X1 | The blob pipeline's line connector is unbounded in CPU and memory on dense fields | can hang WindowServer and end the user session | measured (crash report) | **Do**, first |

### Bugs in the processing core

| ID | What | Effect | Evidence | Rec |
|---|---|---|---|---|
| C1 | Partial-range static run can write an all-ground `reference.tiff` that every later run reuses | wrong output, persistent | read | **Do** |
| C2 | `MemoryMonitor` grants waiters without booking them; fast path jumps the queue | over-admission at barriers | read + reviewer sim | **Do** |
| C3 | `LinearBlobConnector` order dependence → BUG-001 non-determinism | non-deterministic output | read (+ test pending) | **A/B** |
| C4 | Blob/group ids and sizes over 65,535: traps, and `outliers.bin` corruption | crash / corrupt save | read | **Do** |
| C5 | Crashes on edge geometry in horizon refinement and texture search | crash | read | **Do** |
| C6 | `ResourceGovernor` traps on two volumes with the same name (symlinked input) | crash | read + reviewer repro | **Do** |
| C7 | Force-unwrapped C++ results crash the process under OOM instead of failing a frame | crash | read | **Do** |
| C8 | Stale caches: star-aligned mask hash misses small repaints; reference stats keyed by frame index only | stale output | read | **Do** |
| C9 | Cancel during `FrameGraphBuilder.build()` is lost (run continues after Stop) | wrong state | read | **Do** |
| C10 | SIFT keypoint cap is spent before the sky mask is applied | fewer star keypoints | measured (reviewer) | **A/B** |
| C11 | GPU warp projects in float32: 0.72% of pixels sample a different 1/32 px step than CPU | GPU≠CPU output | measured (emulated) | **A/B** |
| C12 | Removal halo is centred 1 px down-right of each pixel | slight output shift | read | **A/B** |
| C13 | `combine()` silently drops blobs that would push a merge past 65,535 px | lost detections | read | **A/B** |
| C14 | Per-frame setting and save-timer races (`set(cleanMethod:)`, `startSaveTimerTask`) | lost edit | read | **Do** |
| C15 | Feature-computation bugs baked into the trained trees | wrong features | read | **Later** (retrain) |

### Speed — output-identical

| ID | What | Measured/expected win | Rec |
|---|---|---|---|
| S1 | Pool Metal textures/buffers; read pyramids straight into `cv::Mat`, outside the GPU slot | keypoint phase (65 s of 131 s) — largest single lever | **Do** |
| S2 | Bind merge inputs in place on discrete GPUs instead of `memcpy` | ~60% of merge slot time | **Do** |
| S3 | Parallelise the SIFT CPU tail (DoG + extremum scan) by row bands, in order | ~15% of busy CPU, on the critical path | **Do** |
| S4 | `mat_wrapper_alias` deep-copies a shared decoded frame | 241 MB + ~138 ms per 42 MP neighbour load | **Do** |
| S5 | Static earth merge pins only ±4 of its 16 neighbours | up to 8 extra decodes per frame | **Do** |
| S6 | Repeated decodes of originals (weak cache) | ~6 decodes/frame measured on LZW input | **Do** (measure first) |
| S7 | Horizon: hoist repeated preprocessing and drop full-res round trips | 1-3 CPU-s/frame | **Do** |
| S8 | Moving-sequence horizon: O(N) reference scans per frame, per-pixel allocations | O(N²) → O(N) | **Do** |
| S9 | Logging: eager interpolation (incl. `await`s), a Task per line, 1 ms poll | hot-loop overhead, out-of-order logs | **Do** |
| S10 | `ResizableGate` starves native-thread acquirers (merges hold CPU slots idle) | throughput when disk-gated | **Do** |
| S11 | Blob pipeline (selective / automatic:true): actor-per-pixel blobber, O(n²) `absorb`, per-group re-decode, dead `LinearBlobExtender` | large on dense fields | **Do** |
| S12 | Smaller identical wins: removal mask, YAML I/O off the pool, AKAZE orientation after cap, horizon accumulate in place, per-pixel `std::set` | small-medium each | **Do** |
| S13 | GPU % metric sums 8 slots and reads "limited by GPU" when it isn't | diagnostics only | **Do** |

### Speed — changes output

| ID | What | Rec |
|---|---|---|
| S14 | Bound the `LinearBlobConnector` neighbour cloud (the BUG-003 fix proper) | **A/B** |
| S15 | Random Walker: shared preprocessing across brushes, faster solver (SOR / red-black) | **A/B** |
| S16 | CPU coverage warp only over the border strips | **A/B** |

### Clients

| ID | What | Rec |
|---|---|---|
| D1 | Daemon: cancelled `Export.RenderSequence` keeps rendering and busy-spins | **Do** |
| D2 | Daemon: `FullSizeGate` lets several 42 MP full-size decodes run at once; waiters not cancellable | **Do** |
| D3 | Daemon: a CANCEL can be handled before its REQUEST | **Do** |
| D4 | Daemon: SIGPIPE kills stard without saving when the client dies | **Do** |
| D5 | Daemon: outlier label PNG rebuilt per call and written in place | **Do** |
| D6 | Config `onUpdate` callbacks stack up per run (daemon, cli, gui) | **Do** |
| D7 | Daemon: client-sent group ids trap on `UInt16(...)` | **Do** |
| G1 | gui: closing a sequence doesn't stop processing, video, or the App Nap activity | **Do** |
| G2 | gui: loading-screen Cancel doesn't cancel; global config manager set at load | **Do** |
| G3 | gui: re-process menu items can start a second run over a running one | **Do** |
| G4 | gui: main-thread and per-tick full-res work (grid slider, open, chart hover, mode list) | **Do** |
| G5 | gui: dropped `.json` errors swallowed; `~/.star.userprefs.json` non-atomic and overwritten after a failed decode | **Do** |
| K1 | Kotlin `StdioConnection`: narrow close race can leave a call waiting forever; no frame-length cap | **Later** |

### Hardening / backlog

| ID | What | Rec |
|---|---|---|
| H1 | Feature YAML and `artifact_inputs.json` written in place; `*.tmp.*` image files left after a crash | **Do** |
| H2 | `shellOut` waits for exit before draining pipes (deadlock if a child writes >64 KB) | **Do** |
| H3 | `HomographyDatabase` keeps a failed sqlite handle; no busy timeout | **Do** |
| H4 | cli progress display repaints every row ~100x per op state change | **Do** |
| H5 | `NativeWork`/`IOWork` over-grant on cancel; `MemoryMonitor.reserve` ignores cancellation | **Hold** |

---

## Details

Paths are relative to the repo root. Line numbers are at `93d7a2b6`.

### X1 — line connector can take the machine down (measured; see finding 8)

`LinearBlobConnector.process` (`LinearBlobConnector.swift:300-336`) adds a child task per
seed (up to `maxBlobsProcessed`, 400 per frame) with no limit; each builds a transitive
neighbour cloud, copies it into a temporary blob via `absorb` (whole-`Set` copy per call,
`Blob.swift:707-715`) and runs a KHT plus line scoring over the cloud's bounding box. This
all runs on the cooperative pool — outside the `NativeWork` CPU gate — and none of it is in
the outlier op's `MemoryMonitor` reservation, which is sized from frame bytes (~0.5 GB at
2300x1450) against observed tens of GB. With the default profile's pipeline depth of
`4 x cores` (72), memory admission is the only limit, so a dense field runs many such
frames at once.

Fix (output-identical parts): bound the connector's in-flight seeds (e.g. a
`LimitedTaskGroup` at a few per frame) and run the heavy per-seed work through `NativeWork`;
make `absorb` update in place (S11); give the outlier op a reservation that scales with blob
count, or an explicit cap. The algorithmic fix is S14. Until X1 lands, never run two
dense-field `selective` runs at once on this machine; use `-n 3`.

### C1 — partial-range static horizon vote (read, high confidence)

`HorizonAccumulator.finalize` votes against `frameCount` (`HorizonAccumulator.swift:77`),
which is `maxFrameIndex + 1` for the whole sequence (`FrameGraphBuilder.swift:703`), but on a
first run only the frames in `range.horizon` have masks; missing files are skipped by
`ia_accumulate_from_files` (`ImageAligner.cpp:1343`) yet still counted. `star -L 99` on a fresh
1000-frame static sequence accumulates ~108 masks against a threshold of 500: every pixel
loses, the merged mask is all ground, and it is written to `horizonReference/reference.tiff`,
which later runs trust (`hasStaticReferenceHorizon`) and never recompute. Two related defects:
disk-loaded masks never set `accumulated[i]` (a second finalize double-counts), and a throwing
accumulate returns nil, discarding every earlier vote.

Fix: count masks actually added and vote against that; mark disk-loaded frames; keep the
previous `accum` on failure; refuse to save a reference that is all ground or all sky.

### C2 — memory gate over-admission (read; reviewer simulation over budget in 192/200 runs)

`drainReadyWaiters` resumes waiters (`MemoryMonitor.swift:951-952`) but `reservedBytes` is
only increased when each resumed task re-enters the actor (`:510`). Every call queued on the
actor in between sees the old total: a second drain admits more, and the fast path at
`:426-445` admits new requests against the stale total — and does not check `waiters` at all
when reality isn't blocking, so it also jumps the queue. At 42 MP one keypoint op is ~5-10 GB;
the burst happens exactly at barriers where dozens of ops arrive together. This is the same
gate whose earlier defects logged the user out.

Fix: book `reservedBytes += waiter.needed` inside the drain at grant time and remove the
post-resume increment; make the fast path require `waiters.isEmpty`. Add a test that
interleaves releases and reserves.

### C3 — BUG-001: `LinearBlobConnector` order dependence (read; determinism test pending)

* Seeds: blobs sorted by size only (`LinearBlobConnector.swift:290`) and cut to
  `maxBlobsProcessed` (400); ties at the cut are broken by Dictionary order, which Swift seeds
  randomly per process.
* Each seed absorbs its `neighborCloud` — a `Set<Blob>`, iterated in random order — into a
  temporary blob, and `absorb` refuses anything past 65,535 px (`Blob.swift:700`). In a dense
  star field the cloud is most of the frame, so *which* pixels get in, hence the fitted line,
  changes every run. The line is then walked across the cloud's whole bounding box, chaining
  unrelated blobs into long straight "lines" — the BUG-001 symptom.
* `compactBlobIds` (`AbstractBlobProcessor.swift:167`) numbers blobs in Dictionary order, and
  `BlobLineTrim` in task-completion order; ids only, but they make outputs harder to compare.

Fix (changes output, deterministically): sort seeds by (size desc, id asc); absorb clouds in
id order; `compactBlobIds` in old-id order. The real fix is S14. Validate with the BUG-001
reproduction (two runs, compare per-frame collateral) and the removal oracle on `a7sii_10`.

### C4 — 16-bit id/size limits (read)

* `Blob.outlierGroup` does `UInt16(self.id)` (`Blob.swift:837`) and `persistentDataArray`
  `UInt16(self.id)` (`:127`, after only logging); `findOutliers(within:)` does
  `currentMaxID + 1` on a `UInt16` (`FrameOutlierProcessor.swift:177`). Each traps past 65,535.
  `compactBlobIds` usually keeps ids small, but nothing guarantees it on a dense field.
* `persistentDataArray` trims a blob of ≥65,535 px to 65,534 pixels but sizes the array from
  the untrimmed count (`persistentDataSizeBytes`, `:147`), leaving trailing zeros. The loader
  advances by the *loaded* blob's size, so every later blob in `outliers.bin` is read from the
  wrong offset (zeros parse as id 0, 0 pixels, and the stream stays misaligned).
* `BlobBinarySaver.save` does `UInt16(blobMap.count)`.

Fix: size from `pixelsToSave`; cap/skip with a warning rather than trap; use checked
conversions and a clear error when a frame exceeds the format. (Widening the format is a
separate, versioned change — **Hold** unless you want it.)

### C5 — horizon edge-geometry crashes (read)

* `FrameHorizonProcessor.swift:935-940`: `for y in bandTop...bandBottom` traps when a column's
  expected Y is ≥ `h + searchRadius` or ≤ `-searchRadius - 1` (inverted range).
  `HorizonCurve.warp` doesn't clamp and `fillEdgeNils` extends edge values, so a rolled horizon
  on a tilting moving sequence can get there.
* `CombinedHorizonDetector.swift:888`: `(searchTop + derivR)...(searchBot - derivR)` needs ≥7
  rows; `Prior.searchFractions` guarantees 2% of a 288-row working image (5 rows).

Fix: clamp/skip empty bands; guard the band height.

### C6 — governor duplicate volume name (read; reviewer reproduced the name collision)

`ResourceGovernor.swift:244` builds `Dictionary(uniqueKeysWithValues:)` keyed by volume
*name*; `IOWork` gates are keyed by device id from `attributesOfItem`, which doesn't follow a
final symlink, while names come from `statfs`, which does. A symlinked input dir pointing at
another volume yields two gates with one name → trap within ~5 s of the first tick. Fix: key
by gate id; resolve symlinks before computing the id.

### C7 — force-unwrapped C++ results (read)

`ImageAligner.swift:43, 57` (`MatWrapper(ref: r!)`), and implicitly-unwrapped returns in
`createGradientMaskIntoSky`, `ensure16Bits`, `BufferHolder.toMat`. The C++ side returns null
on any caught exception (e.g. failing to allocate a 253 MB output), so OOM becomes a SIGTRAP of
the whole run instead of one failed frame. Fix: return optionals and fail the op.

### C8 — stale horizon caches (read)

* `StarAlignedHorizonMask.swift:160` hashes ~1 in 643 pixels at 42 MP; a 50x10 px repaint has
  ~46% odds of the same digest, and `invalidateAll` (`:138`) has no callers. Fix: hash the
  per-column horizon Y (~8 K ints), and invalidate on reference save.
* `ReferenceHorizonStats.swift:218`: process-wide cache keyed by frame index only, never
  cleared, ignoring `referenceHorizonNeighborhoodSize` and bucket count. In the gui/daemon a
  second sequence gets the first one's statistics. Fix: key by sequence path + those values.

### C9 — cancel lost during graph build (read)

`FrameGraphBuilder.build()` suspends many times before `queue.addOperations` (`:1201`); a
`cancelAllOperations()` in that window finds an empty queue, and the build then enqueues the
whole graph. `cancelAllOperationsAndWait` sees `operationCount == 0` and reports drained.
gui Stop while a long sequence is being surveyed keeps running; `updateSettingsAndProcess` can
build a second graph over the same frames. (The daemon already works around it,
`Session.swift:373-375`.) Fix: a cancel generation captured at build entry; skip enqueue if
it changed; make the wait also wait for in-progress builds.

### C10 — SIFT cap spent before the mask (measured by reviewer on real a9-1 frames)

Both the GPU port (`SIFTDetector.cpp:634-645`) and the `cv::SIFT` fallback apply the
detection mask *after* `retainBest(nfeatures)` — that is upstream OpenCV's order too. So
`ImageAligner.cpp:1490-1494`'s premise ("applied to the mask … so the step cannot use up SIFT's
keypoint cap") is false: keypoints outside the mask consume the 2000 slots and are then
discarded. a9-1 frame 119: 1809 returned with 3529 in-mask available; frame 299: 1932 vs
4033; 272 of 1351 sky files have 1600-1899. Fix (changes output — more star keypoints on
moonlit/twilight frames): in the port, rescale + mask, then `retainBest`; for the fallback,
detect uncapped with the mask, `retainBest`, then compute descriptors. Bonus: the port can
then skip the extremum scan outside the mask. Validate with the homography recompute harness
and reciprocity check.

### C11 — GPU warp precision (measured by emulation)

`GPUOps.swift:383, :613` hand the kernel a float inverse homography and `warp_tap`
(`:1412-1437`) projects in float32, compiled with default (fast-math) options. Emulating the
kernel's math in IEEE float on a real 6000x4000 −4 homography: 0.72% of interior pixels land
on a different 1/32-px interpolation step than OpenCV (channel deltas p50 15, p99 118, max
1531 /65535), growing with width. Fix: per-row terms computed in double on the CPU (or
two-float arithmetic); compile the warp without fast math (it may also fold the `isfinite`
guard). Add a full-size GPU-vs-CPU test.

### C12 — removal halo off-centre (read)

`RemoveMask.swift:29` sets `center = Int(radius + 1)`; `computeRemovalMask` offsets by
`Int(removeMask.radius)` (`FrameAirplaneRemover.swift:1330`), so the halo is centred 1 px
right and down of each removed pixel. Fix: offset by `removeMask.center`.

### C13 — merges drop blobs (read)

`combine()` (`HoughLineMatrixBlobConnector.swift:297-304`, used by both connectors) is handed
blobs already removed from the map; when `absorb` refuses one (65,535 px cap) it is never put
back, so its pixels vanish from detection. Fix: return the refused blobs and reinsert them.

### C14 — read-modify-write races (read)

* `FrameAirplaneRemover.swift:1671-1677`: `set(cleanMethod:)` reads the config, edits
  `pixelReplacementOverrides[frameIndex]`, writes it back from `MainActor.run`; two frames
  changed back to back lose one override, and the loss is saved to `config.json`. Fix: do the
  edit inside one `ConfigManager` call.
* `:300-309`: a finishing save timer sets `saveTimerTask = nil` unconditionally, dropping a
  replacement installed meanwhile, which then can't be cancelled and saves mid-edit. Fix:
  clear only if it is still the same task.

### C15 — feature bugs in the trained trees (read; do not fix without retraining)

`OutlierGroup.swift:779/801` measures from `intersections[0]` while walking from
`intersections[1]`; `Blob.intensity()` sums `UInt64(pixel.intensity)` where `intensity` is a
0-1 `Double`, so it is always ~0 (`Blob.swift:624`, `.averagebrightness` is dead);
`OutlierGroupFeature.swift:650` counts diagonal neighbours only (`pixelBorderAmount`, used in
2,624 tree splits); `HoughLineMatrixBlobConnector` scores lines on the blob-*id* image, not
brightness (`:204-211`). Recommendation: record in `BUGS.md`, fix together at the next tree
retraining.

### S1 — Metal resource churn and read-back in the GPU pyramids (measured)

Per SIFT call `buildSiftPyramidImpl` creates ~`nOctaves × 6` `.managed` textures plus scratch
(`GPUOps.swift:942-990`); AKAZE also creates one per FED sub-step (`:1293`). Read-back
(`matWrapper(fromFloatTexture:)`, `:1352-1364`) zero-fills a `[Float]`, de-tiles into it with
`getBytes` on the CPU, then `mat_wrapper_create(..., takeOwnership: true)` clones it again. All
of it runs inside `withGPUSlot`, which is what the governor reports as GPU busy.

Fix, in order of expected payoff:
1. A per-device texture pool keyed by (width, height) (or an `MTLHeap`), reused across calls
   and frames; bounded, and released under memory pressure.
2. Read straight into a `cv::Mat` allocated by a new `mat_wrapper_new(...)`: one pass, no
   zero-fill, no clone.
3. Release the GPU slot before read-back: blit each level into a pooled linear
   `MTLBuffer` on the GPU (the blit engine de-tiles), end the slot, then copy out on the CPU.

Keep the documented `.managed` requirement for textures on the Vega (`:870-879`); revisit
`.shared` on Apple Silicon. Output identical (same kernels, same bytes). Measure: keypoint
phase wall time, sys time, and the slot breakdown script from this review.

### S2 — in-place binding for merges on discrete GPUs (measured by reviewer)

`runMerge` uses `bindInPlace` only when `device.hasUnifiedMemory` (`GPUOps.swift:728-734`);
on the Vega every merge allocates a shared buffer and `memcpy`s all 9-17 sources into it
(`bindByCopy`, `:807-841`) — the inputs are read over PCIe either way. Reviewer measured on
this Vega: `makeBuffer(bytesNoCopy:)` works (including at an offset and after CPU writes);
512 MB wrap 0.00-0.08 s vs copy 0.50-0.69 s on 8 threads; GPU read time unchanged. Fix: use
`bindInPlace` for inputs on discrete GPUs too, keep the managed output + copy-out, fall back to
copying only when a wrap fails; pool the managed output buffers. Output identical.

### S3 — parallel SIFT CPU tail (measured)

After the GPU pyramid, `detectAndComputeImpl` builds the DoG pyramid with serial
`cv::subtract` (`SIFTDetector.cpp:162-174`) and scans each DoG layer for extrema on one thread
(`:338-420`). Fix: run `buildDoGPyramid` levels in parallel (or compute DoG on the GPU inside
S1's command buffer); split `findScaleSpaceExtrema` into row bands with per-band keypoint
vectors concatenated **in band order**, which reproduces the serial order exactly. Update the
"not the hot path" comment. Output identical (prove with the `#include`-the-real-`.cpp`
differential harness from the merge work).

### S4 — `mat_wrapper_alias` copies when shared (read; reviewer reproduced)

`mat_wrapper_alias` goes through `MatWrapperImpl(Adopt{}, ...)`, whose `canAdopt` requires
`refcount == 1` (`MatWrapperImpl.hpp:75-80`). The first alias of a `DecodedFrameStore` frame
shares it; every further concurrent alias deep-copies it — exactly the 241 MB / ~138 ms copy
`ImageCache.swift:31-36` says this path avoids, and untracked by `MemoryMonitor`. Adjacent
frames share most of their neighbours, so this is the common case. Fix: alias always shares
when the buffer is OpenCV-owned, continuous and not a submatrix; keep the refcount rule for
`wrap()` only. Output identical.

### S5 — static earth merge pinning (read)

`pinNeighborDecodes` pins `alignmentFilenames` (±4, `FrameAlignmentProcessor.swift:137-147`);
the default static earth merge uses 16 neighbours (`:979-989`), so ±5..±8 decode uncached
unless another op happens to hold them. Fix: pin `staticNeighborFrames` too when the static
merge will run (the op's reservation already covers them). Output identical.

### S6 — repeated decodes of originals (measured on LZW input)

Base frames load through the weak Swift `ImageCache` (`ImageAccessor.swift:249`), neighbours
through `DecodedFrameStore`; a frame decoded by one op is gone by the next, and the same
original can be decoded and held twice concurrently. Step 1 (cheap): log
`DecodedFrameStore.decodeCount` and `ImageCache` misses per run and per frame. Step 2, if the
count is high: route base-frame loads through `DecodedFrameStore` with the op's pin, and/or
offer an "uncompressed working copy" of compressed inputs (LZW/ZIP TIFF, JPEG) in the temp
dir so later reads take the existing direct-read path. Output identical.

### S7 — horizon detector waste (read; reviewer benches, rough under load)

* `runDP` calls `pib_dp_horizon_mask` 36 times (`CombinedHorizonDetector.swift:417-426`), each
  redoing grey/`ensure8U`/Sobel/Canny (`PixelatedImageBridge.cpp:771-805`) — ~50% of
  0.45-0.85 CPU-s/frame. Hoist.
* `runOtsu`/`runDP` upscale to full res, `thresholdToBinary`, then `extractHorizonY` again;
  `extractHorizonY(thresholdToBinary(m)) == extractHorizonY(m)`. The Random Walker path builds
  a full-res mask per brush only for `selfScore` to re-extract Y already in `resultY`. ~7
  column-wise full-res scans + 5 mask builds per frame. Drop them; build only the winner; scan
  row-wise. Route `runOtsu`'s tail through `NativeWork`.
* `pib_ground_only` / `sky_only` / `filter_connected_components` look up a `std::set` per
  pixel (`PixelatedImageBridge.cpp:189`): 160-210 ms → 45-57 ms with a label LUT.
* `ia_accumulate_one_horizon_mask` clones the 168 MB accumulator per frame on the actor
  (`ImageAligner.cpp:1318-1331`): add in place, via `NativeWork`.

### S8 — moving-sequence horizon scaling (read; reviewer bench)

* `nearestReferenceMasks` (`FrameHorizonProcessor.swift:597-613`) builds a path and calls
  `fileExists` for every frame of the sequence, and is reached three times per frame on every
  moving run: ~180 ms per scan at N=2000, ~18 CPU-minutes total. List `horizonReference/` once,
  cache, invalidate on save.
* Brightness refinement allocates two `[Double]` per pixel (`:951-952`) over ~1.6 M px/frame:
  2.9 s → 0.88 s hoisted (identical). Run the refinement through `NativeWork`.

### S9 — logging (read)

`Log.*` take `String`, so every call site's interpolation runs even when filtered — including
`await blob.size()` / `await blob.boundingBox()` in per-blob lines (`BlobLineTrim.swift:193,
196`, `LinearBlobConnector.swift:544, 553`). Each enabled line spawns a `Task` with three actor
hops (`Log.swift:902-957`), so lines can be recorded out of order (which matters for
crash-tail diagnosis — see BUG-005), and the drain loop polls every 1 ms forever
(`:1028-1035`). Fix: `@autoclosure` messages (turns the `await`-in-message sites into compile
errors to fix), synchronous enqueue under a lock, continuation-woken drain.

### S10 — `ResizableGate` fairness (read)

`release()` grants the slot to the first suspended Swift waiter, then broadcasts; a native
thread in `acquireBlocking` (`ResizableGate.swift:64-69`) wakes to a full gate. Native callers
are the C++ merges loading neighbours (`DecodedFrameStore` → `IOWork.runBlocking`), each
holding one of the CPU slots while starved. Fix: one FIFO for both kinds (park native threads
as waiters with their own condition).

### S11 — blob pipeline (selective / automatic:true) (read; reviewer micro-benchmarks)

* `FullFrameBlobber`: 12-14 actor calls per blob pixel (`PixelStatusTracker`, `Blob.add`,
  `size()`), three array allocations per `neighbors()` call, and `[[SortablePixel?]]` at 24 B
  stride (~1.0 GB at 42 MP, plus 337 MB of status). Rewrite with synchronous row-major
  arrays and per-blob pixel lists, building `Blob`s at the end in the same id order; keep the
  duplicate pushes in `expand` (the contrast threshold depends on blob size at check time). A
  stable counting sort on the 16-bit values reproduces today's order. Identical output; ~1.2 GB
  less per in-flight blob op at 42 MP.
* `Blob.absorb` copies the whole growing `Set` on every call (`Blob.swift:707-715`) and hops to
  the status-tracker actor per pixel: update in place.
* `borderBrightness` decodes the original once per *group* (`OutlierGroupFeature.swift:667`,
  weak cache): load once per frame and pass it in.
* `LinearBlobExtender` cannot absorb anything: `iterationBlob` starts nil and is only set
  inside the branch that requires it non-nil (`LinearBlobExtender.swift:204, 308, 338`); its
  loop also `return`s from the task group at the first small blob. Remove the step (identical
  output, saves a full `BlobAnalyzer` build per frame); fixing it instead would change output
  and need retraining.
* `HoughLineMatrixBlobConnector`: per-pixel async closures + actor hops (`:340-408`) → the
  synchronous `Line.iterate`; skip the unused `pixelScore`; split the image once; skip empty
  tiles.
* `AbstractBlobProcessor.swift:267` loads the full original that `FullFrameBlobber` never reads.

### S12 — smaller identical wins (read)

* `computeRemovalMask` (`FrameAirplaneRemover.swift:1347-1348`): `maskY` innermost (strided),
  361 mask taps per removed pixel, 337 MB `[Double]` at 42 MP. Swap loops; store mask index
  as `UInt8`; or compute with a grey dilation — exact either way.
* `OCVFeatureSet.load` in `AlignmentValidationOp.swift:200-204` task children and
  `results.write` in `FrameAlignmentProcessor.swift:700`: 0.1 s each, blocking the cooperative
  pool → `NativeWork`.
* AKAZE port computes orientation for every candidate (15-80 k) before mask + cap
  (`AKAZEDetector.cpp:801-805`): move after.
* `ImageBuffer.image` copies the buffer despite the comment (`BufferHolder.cpp:71-72`).

### S13 — GPU utilisation metric (measured)

`gpuPercent = Δ(sum of time inside any slot) / window` capped at 100
(`ResourceGovernor.swift:262`), so one busy slot of eight reads 100% and the log says "limited
by GPU" while the device idles. Fix: report slot occupancy separately from device busy time
(from `MTLCommandBuffer.gpuStartTime/gpuEndTime`).

### S14 — bound the neighbour cloud (changes output)

`neighborCloud` (`BlobAnalyzer.swift:250-276`) is the transitive closure of blobs within
`scanSize` (10 px) — in a dense field, most of the frame — rebuilt independently for each of
400 seeds, each followed by a KHT over the cloud's bounding box and line scoring over up to
500 lines × 65 k px. Options: cap the cloud by distance from the seed (not transitive), or
compute connected components once and share them; skip seeds whose cloud was already
processed. Validate on the crop (BUG-003 time, BUG-001 collateral) and `a7sii_10` removal
oracle; may need retraining if `.linear*` features shift.

### S15 — Random Walker (changes output slightly)

Single-threaded Gauss-Seidel up to 150 + 300 iterations (`RandomWalkerHorizon.cpp:202-258,
524-555`); full-res LAB/grey conversion before downscaling (`:337-353`); crop, LAB, three
bilateral passes, median and Sobel repeated per brush. Options: share preprocessing across
brushes; SOR (ω≈1.8) or red-black parallel GS. Validate against the reference masks with the
existing horizon measurement tests (`HorizonScoringMeasurement`).

### S16 — CPU coverage warp (changes output possibly; CPU path only)

`ImageAligner.cpp:3966-3971`: the coverage probe warp costs ~60% of the image warp per
neighbour (0.90 vs 1.36-1.66 core-s at 24 MP). Compute the certainly-covered interior from H
in double and warp only the border strips. OpenCV rounds per block, so A/B for identity.
Benefits Linux, Windows and GPU-less Macs.

### D1-D7 — daemon (read)

* **D1** `ExportHandlers.swift:35-94`, `Session.swift:812-820`: on CANCEL or session close
  only `finishTask.cancel()` runs; the task group keeps adding renders, `renderNow` never
  checks `closed`, and `waitForSave`'s `try? await Task.sleep` throws immediately when
  cancelled, so it busy-polls `savingState()` until each save ends. The stream also stops on
  *any* `.sequenceState` (e.g. `Processing.Cancel`'s "cancelled"). Fix: check cancellation
  before each `addTask` and in `renderNow`; return false when the sleep throws; break only on
  the render's own sentinel.
* **D2** `PreviewFiles.swift:84-98` `FullSizeGate`: after `busy = false` + resume, a new caller
  can enter before the resumed one; waiters ignore cancellation. Fast frame stepping in the
  Kotlin full-res view decodes every 42 MP frame, several at once. Fix: hand the slot directly
  to the next waiter; cancellable waiters; re-check cancellation before starting.
* **D3** `Stard.swift:142-143`: request and cancel each get their own unstructured `Task`, so
  the cancel can reach the dispatcher first and be dropped. Fix: one ordered consumer, or
  remember early cancels.
* **D4** No `SIGPIPE` handling; `outHandle.write(Data)` raises on a broken pipe. Client death
  mid-run kills stard without `session.close()` / pending saves. Fix: ignore SIGPIPE, use
  `write(contentsOf:)` and treat failure as EOF, run the close path on EOF.
* **D5** `FrameHandlers.swift:82-117`: rebuilds an 84 MB label buffer + full-res 16-bit PNG
  per call, written in place to a fixed path; a forced reload can read a torn PNG. Fix: cache
  per outlier-groups version; temp + rename.
* **D6** `Session.swift:289, 661`, `FrameGraphBuilder.swift:94-102`, `Config.swift:80`: every
  start appends another `onUpdate` closure. Fix: register once per session/builder.
* **D7** `OutlierHandlers.swift:164, 223, 363`: `UInt16(req.groupID)` etc. → `UInt16(exactly:)`.
  Also cap frame length in `readFrame`.

### G1-G5 — macOS gui (read)

* **G1** `ViewModel.swift:403-414` `unloadSequence()` only nils the sequence: no
  `stopProcessing()`, `stopVideo()`, or `disable()` (the only caller of
  `appNapDisabler.end()`, never called), so each closed sequence keeps its graph running and
  leaks an `idleSystemSleepDisabled` activity.
* **G2** `ImageSequenceLoadingView.swift:66-68`: Cancel doesn't cancel the load task, which
  later assigns `imageSequence`; each load also sets the global
  `frameGraphBuilder.set(configManager:)` (`ImageSequenceViewModel.swift:2116`), so the shown
  sequence can be processed with another's config.
* **G3** `ImageSequenceViewModel.swift:2972-2980`: `//if isProcessingFrames { return }` is
  commented out; re-process menu items build a second graph over a running one and clear
  `isProcessingFrames` when the small one ends. Fix: go through the cancel-and-wait path.
* **G4** Grid slider decodes every frame's full-res horizon mask per tick
  (`GridView.swift:36-38` → `FrameViewModel.swift:543-560`); opening a sequence sets each
  frame's `.frame` twice with main-actor file checks and full-res mask decodes
  (`FrameViewModel.swift:114-140`); alignment chart `points` is recomputed ~7x per hover with
  `UUID()` ids (`AlignmentWindowView.swift:123-124, 353-368`); `visibleModes` stats the disk per
  frame per redraw (`GridLeftPanel.swift:90-101`).
* **G5** `InitialView.swift:161-180`: the `try`s are inside `Task {}` so the `catch` never
  runs; `UserPreferences.swift:259-272, 216-233`: delete-then-create save (shared with the
  Kotlin client) and a failed decode leads to overwriting the file with defaults. Fix: atomic
  write; never save over a file that failed to decode.

### H1-H5 — hardening

* **H1** `OCVFeatureSet.cpp:104-112` and `ArtifactInputs.swift:507` write in place; a file cut
  just before `stars:` loads silently without stars. `MatWrapper.cpp:462-466` temp files
  (`NAME.tmp.<pid>-<seq>.tif`) survive `_exit`/OOM kill and match `ImageSequence`'s `.tif`
  filter. Fix: temp + rename; sweep `*.tmp.*` at run start.
* **H2** `ShellOut.swift:34-37`: `waitUntilExit()` before reading either pipe; a child writing
  >64 KB to one pipe deadlocks. Callers pass `-v error` today, so latent. Fix: drain both
  pipes concurrently.
* **H3** `HomographyDatabase.swift:130-135`: a failed `sqlite3_open` handle is kept; no
  `sqlite3_busy_timeout`.
* **H4** `UpdatableLog.swift:168-213`: every update re-sorts and reprints every row, ~100 row
  repaints per op state change, error rows accumulate forever. Throttle to ~4 Hz, cap errors.
* **H5** `ResizableGate` over-grants a cancelled waiter (`:87-94`) and neither `NativeWork.run`
  nor `IOWork.run` checks cancellation afterwards; `MemoryMonitor.reserve` ignores
  cancellation. **Hold**: changing this alters cancel semantics everywhere; I'd fold it into C9.

---

## Not proposed (already measured or decided)

`mergeLoadConcurrency > 1`, lowering `mergeStreamingThresholdMB`, AKAZE threshold above 1e-4,
keypoint divisor, `warpAffine`, OpenCL/T-API, `cv::setNumThreads`, GPU for
`FullFrameBlobber`/DP horizon/TIFF decode, horizon scoring weights/shapes, wiring
`HomographyHorizonDetector` Pass 2.

## Not covered

The Kotlin client beyond its stdio transport; the decision-tree generator and training tools
(two latent `LimitedTaskGroup.next()` bugs noted there); release scripts. BUG-005 (SIGSEGV after
the static horizon merge): no defect found on that path; the next step is the `.ips` crash
report, and S9 makes the log tail trustworthy.

## Verification approach for the guide

* Output-identical items: A/B the cli on fresh copies of `test_a7sii_10` (see project memory
  `cli-behaviour-verification`), compare every output TIFF with `magick compare -metric AE`;
  for C++ kernels use the `#include`-the-real-`.cpp` differential harness.
* Speed: CPU-seconds (`/usr/bin/time`), the slot-breakdown sampling used here, and min-of-K
  kernel timings — not single end-to-end wall clocks on this machine.
* Safety while testing: one dense-field (`a7sii_10_crop16`) run at a time, `-n 3`, `nice`,
  and a watchdog that kills the run on high RSS or low system free memory — two at once
  crashed the session on 2026-10-22 (finding 8).
* Output-changing items: the removal oracle (`a7sii_10` labels), homography recompute and
  reciprocity harnesses, horizon reference masks; tree retraining where noted.
