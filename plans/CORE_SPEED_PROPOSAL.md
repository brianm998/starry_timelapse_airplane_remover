# Core speed: where a run's time goes now, and what to do about it

A proposal and handoff, written 2026-10-29 on `develop` at `961a52f5` (0.12.6 plus that day's
cloud-aware merge work). It assumes no memory of the session that produced it. Every number
was measured on this iMac Pro (18-core Xeon W-2191B, 36 threads, 128 GB, Vega 64) unless it
says *estimate*.

Read first, for what is already done and why: `CODE_REVIEW_PROPOSAL.md` (S1–S16; everything
but S6 steps 2–3, S15 and S16 landed), `RESOURCE_SCHEDULING_DESIGN.md` (gates, ledger,
`IOWork`, `DecodedFrameStore`) and `GPU_ACCELERATION_PROPOSAL.md`. Nothing below repeats an
item those cover, except where a new measurement changes its priority.

## Summary

The user's real workload is long **moving** sequences at 24 MP (6000×4000 16-bit TIFF,
1,300–2,100 frames) driven from the macOS GUI, with GPU keypoints on and, on this Vega,
**GPU merges off** (`useGPUForMerge: false` in `~/.star.userprefs.json`). On that workload:

* A run is phase A (horizons, keypoints, homographies, ~63 min for 1,407 frames), then
  **2–4 min of horizon consensus with the CPU idle**, then merges. Merges now run at
  **10.2 frames/min, ~120 CPU-s per frame** on the CPU path with the cloud stage on — about
  140 min for 1,407 frames, ~70% of the run.
* **The macOS GUI compiles all of StarCpp at `-Os`**; the cli and daemon get `-O2`. The median
  kernel is **1.7x slower at `-Os`**, its sort 3.4x. This is the cheapest win in the codebase.
* **~93% of merge-phase CPU is five C++ kernels**: the sigma-clip median, OpenCV's
  `warpPerspective` (whose 16-bit path is scalar and mallocs per row block), the cloud
  stage's `remap`, and the cloud stage's map and blur loops. Decodes are 0.8%.
* The median kernel can be made **2.1x faster, bit for bit** (prototype; 0 of 3.07M
  adversarial pixel-channels differ) with exact integer statistics plus AVX2 dispatch.
* The composite **discards ~75% of the earth merge and ~10% of the star merge**. Not
  computing those rows is identical for final frames: *estimate* ~25% of the merge phase.
* In phase A, **brute-force descriptor matching is 16% and is done twice per pair** on moving
  sequences, and **~10% is one `memcpy`** of the GPU SIFT/AKAZE pyramids into fresh Mats.

Order, by payoff over risk:

| # | what | identical? | effort | expected win |
|---|---|---|---|---|
| R1 | GUI: StarCpp at `-O2`/`-O3` | verify | hours | 15–25% of GUI merge CPU, plus every StarCpp loop in phase A |
| R2 | median kernel: exact stats + AVX2 | yes | 1–2 d | ~25% of merge CPU (x86) |
| R3 | exact SIMD 16-bit warp, analytic coverage, row ranges | yes | 2–3 d | 25–35% of merge CPU (cli profile) |
| R4 | merge only the rows the composite reads | final frames yes | 2–3 d, after R3 | ~25% of merge CPU, moving; more on static earth |
| R5 | horizon consensus from per-frame line sidecars | yes | 1 d | 2–4 min serial gap per run |
| R6 | match each neighbour pair once | yes | 2 d | ~8% of phase A |
| R7 | SIFT/AKAZE pyramid readback without the copy | yes | 1 d | ~10% of phase A |
| R8 | AKAZE port sparse scans; mask caches | yes | 1–2 d | ~6% of phase A |
| R9 | cloud stage leftovers; GPU port on Apple Silicon | yes | 2 d+ | most of the cloud stage's CPU |
| R10 | stall watchdog, HT width, ledger estimate | n/a | small each | diagnosis and headroom |

Plus one decision for Brian: the final output's LZW compression costs **12.7% of the cli's
merge-phase CPU** for a 0–8% size saving (§1.4, Q4).

## 1. What was measured

### 1.1 Sources

| run | where | settings | used for |
|---|---|---|---|
| a9-3, 1,407 × 24 MP, 10-28 | `~/Library/Logs/star/Star-logs-2026-10-28-16-14-58.txt` | Full, moving, GPU SIFT/AKAZE, GPU merge configured on, cloud v1 | run structure |
| a9-3 re-merge, 10-29 | `…2026-10-29-16-49-25.txt` + a 15 s `sample` of the live GUI at 17:11 (Full) | Full, CPU merges, cloud v2 | GUI merge profile |
| a9-1, 1,865 × 24 MP, 10-29 | `…2026-10-29-11-33-12.txt` | Full → Balanced → Light | consensus under Light |
| probe: frames 645–674 of a9-1 07_11 | release cli from this worktree, `--use light --moving-camera --no-use-gpu --cloud-aware-merge`, `nice 10`, `sample` every ~16 s | cli phase-A and merge profiles |

The probe's inputs are hard links in `/Volumes/sp/tmp/claude_speed_probe/LRT_probe_a9_30`
(no extra disk). Before each run, link the painted reference into a fresh temp dir so the
horizon prior takes the production path — a run's cleanup deletes it:
`mkdir -p …/claude_speed_probe/star_temp_LRT_probe_a9_30/horizonReference && ln
/Volumes/sp/tmp/star_temp_LRT_07_11_2026-a9-1/horizonReference/image_0657.tiff` into it.
Delete the generated `-star-v-*` output dir after each run (it is real data, ~4 GB), and the
whole `claude_speed_probe` directory when the work is done.

Probe totals: 1,077 s wall (phase A 462 s, merges 609 s), **2,992 s user + 525 s sys ≈ 117
CPU-s per frame**, 13.7 GB peak footprint. Sys time is 15% of the CPU.

Attribution note: `cv::parallel_for_` bodies run on GCD worker threads whose stacks do not
include the caller, so CPU was attributed by the kernel's own symbol, not by caller.

### 1.2 Run structure (a9-3, 10-28, Full)

| stretch | time | |
|---|---|---|
| phase A | 63.0 min | CPU 77–100%, GPU 10–30% |
| validation | ~3 s | |
| **horizon consensus** | **184 s** | CPU ~20%; no merge can start before it |
| merges | 67 min | 21.7 frames/min, CPU 100% |

Phase-A per-op wall medians (18 ops in flight): horizon detection 17.8 s, merged horizon
13.3 s, sky keypoints ~62 s, each homography set ~2 s.

Consensus at Full across five runs: 124, 134, 184, 218 s (1,312–2,122 frames). On the a9-1
run under Light (one disk stream) it took **618 s**.

Unexplained: on 10-28 the log is **silent from 16:52:10 to 16:54:37** — governor at CPU 0%,
GPU 0%, 0 MB/s, disk gate 8/8 held with 41 waiting — then frames trickle one at a time until
~16:57:36. It looks like the process was stopped from outside (project memory
`processes-sigstopped-on-this-mac`), but nothing in the log can say. See R10.

### 1.3 Merge phase in the GUI (10-29, Full, CPU path, cloud stage on, StarCpp at `-Os`)

114 frames completed 17:04:27–17:15:35: **10.2 frames/min**, governor "CPU 100% (gate 18/18)",
`ps` ~2,050% → **~120 CPU-s per frame**. The same phase on 10-28 (GPU merge on, cloud v1) was
21.7 frames/min, ~57 CPU-s per frame.

| kernel (by own symbol) | share of busy CPU |
|---|---:|
| `medianMergeTyped<uint16_t>` (star, cloud stack and earth merges) | **48.6%** |
| `WarpPerspectiveInvoker` (16-bit warps + 8-bit coverage probes) | 17.0% |
| `RemapInvoker` (cloud layers + their probes) | 13.4% |
| cloud map/field lambda (`ImageAligner.cpp:4046`) | 8.2% |
| cloud box blur / luma / low-pass (`cloudaware::`) | 6.0% |
| GUI main thread (SwiftUI; a quarter of it `AlignmentDeviationChart`) | 3.4% |
| decodes | 0.8% |

Inside the cloud stage (35% of the phase, inclusive): per-neighbour layer build 53% (of
which `cv::remap` 63%, the map lambda 35%), the cloud-stack median 26%, `lowPass` 15%, box
blurs 11%.

### 1.4 Merge phase in the cli probe (`-O2`, CPU path, cloud stage mostly pre-filtered out)

| kernel | share |
|---|---:|
| `WarpPerspectiveInvoker` | **52.0%** |
| `medianMergeTyped` | 28.5% |
| **LZW encode of the output TIFF** (`TIFFWriteScanline` ← `cv::imwrite`) | **12.7%** |
| cloud stage | 2.4% |
| decodes | 0.7% |

Inside `warpPerspective`, in both builds: ~36% `remapBilinear<Cast<float,ushort>, RemapNoVec>`
(OpenCV's 16-bit bilinear is **scalar**), ~17% map generation
(`WarpPerspectiveLine_SSE4_Impl`), ~14% the 8-bit coverage-probe warps, **~10% malloc/free**
churn per row block, 4% the NEAREST mask warps of `StarAlignedHorizonMask`.

The GUI and cli differ mostly because of `-Os` (§1.6) and because the GUI's sequence is
cloudy. Expect the GUI to look like the cli — warp-dominated — once R1 lands.

### 1.5 Phase A in the cli probe (GPU SIFT and AKAZE on)

721,515 busy samples over horizon detection, keypoints and homographies:

| step | share | notes |
|---|---:|---|
| AKAZE CPU tail (Hessian, extrema, refine, orient, describe) | 16.8% | 5.1% of phase A is out-of-line `Mat::at<uchar>` in `AKAZEDetector.cpp:457–550` |
| **descriptor matching, `BFMatcher::knnMatch`** | **16.1%** | SIFT L2 ~8.2%, AKAZE Hamming ~6.2% (`ImageAligner.cpp:2649`) |
| SIFT CPU tail (DoG subtract, extrema, descriptors) | 14.0% | |
| horizon detection, other | 10.3% | detector, Lab, refinement, despike |
| **SIFT pyramid readback `memcpy`** | **8.1%** | `GPUOps.swift:1687` |
| keypoint preprocessing (masks, CLAHE, stretch, dilate, `distanceTransform`) | 6.9% | |
| Random Walker solve | 5.6% | `gaussSeidelWithData` |
| decode | 4.1% | |
| bilateral ×3 | 3.6% | `RandomWalkerHorizon.cpp:373` |
| AKAZE pyramid readback `memcpy` | 1.7% | |
| other | ~13% | |

(An earlier window of only the first 14 samples, horizon-heavy, had the Random Walker at
15.7%. The table is the whole phase.)

### 1.6 Build flags

`gui/DerivedData/…/ArchiveIntermediates/Star Release/…/StarCpp.build/Release/{StarCpp,kht}.build/Objects-normal/{x86_64,arm64}/*common-args.resp`
says **`-Os`**, both architectures. SwiftPM release (cli, daemon, `cli/.build/release.yaml`):
`-O2`. Neither has `-march`; x86 is the SSE2 baseline. OpenCV is prebuilt with its own flags
and its own runtime dispatch, so this affects only star's C++.

Median kernel body, same source: 567 instructions (GUI) vs 1,075 (cli). Standalone, single
thread, 9 real 24 MP sources, a 6000×1600 band:

| flags | ns per pixel-channel | sort alone |
|---|---:|---:|
| `-O2` | 80.5 | 16.0 |
| `-Os` | **135.4** | **54.7** |

The machine was loaded (the user's own run and a build): read ±20% as noise, the 1.7x as
real. The codegen difference says the same.

## 2. Recommendations

**Identical** = output byte-identical before and after. **Changes output** = needs an A/B
with the removal oracle, the homography harnesses or the horizon reference masks.

### R1 — Build StarCpp at `-O2` or `-O3` in the GUI (verify identical, hours)

* **What.** Make Xcode's Release build compile the `StarCpp` and `kht` targets at `-O2`
  or better. First try `.unsafeFlags(["-O3"], .when(configuration: .release))` in
  `StarCpp/Package.swift`'s `cxxSettings` (it already uses `unsafeFlags`; local packages may)
  and check the `.resp`: clang takes the last `-O`. Fall back to a project-level setting if
  Xcode puts its `-Os` after the package's flags.
* **Why.** §1.6. The median kernel, the cloud stage, the SIFT/AKAZE CPU tails, the Random
  Walker, the DP horizon and KHT all run at `-Os` in the GUI.
* **Win.** StarCpp-owned kernels are ~63% of the GUI's merge phase; at 1.3–1.7x that is
  **15–25% of GUI merge-phase CPU** (*estimate*), plus a share of phase A.
* **Identity.** Integer kernels cannot change. Float code (cloud stage, RW, AKAZE port) can
  change only if contraction or reassociation differs between optimisation levels; with no
  `-ffast-math` it should not. Prove it: the same 20 frames through a GUI-built StarCore and
  through the cli, `cmp` every output, before and after. If they already differ before,
  record that as a finding.
* Pick `-O2` vs `-O3` by timing both on the median kernel and the RW solve.

### R2 — Median kernel: exact integer statistics + ISA dispatch (identical, 1–2 days)

* **Where.** `medianMergeTyped`, `ImageAligner.cpp:263`, the blocked path.
* **What.** Keep the sorting network. Replace the per-lane Welford pass (a double divide
  per source per lane) with exact sums: every value is < 2¹⁶, so `S = Σv` and `Q = Σv²` over
  the counted sources are integers below 2⁵³ and exact in `double`. `D = c·Q − S²` is
  exact; `threshold = (S + k·√D)/c` is one sqrt and one divide per lane. Count "below"
  against it. Per lane, fall back to the existing Welford only when a counted value lies
  within `1e-6·(1+|threshold|)` of it, and short-circuit lanes whose counted values are all
  equal (every index gives the same value). Compile the function for AVX2
  (`__attribute__((target("avx2")))`) and dispatch on `__builtin_cpu_supports("avx2")`;
  arm64 has NEON as its baseline — measure it there. Also: for `uint16_t`, sort in 16-bit
  lanes biased by `0x8000` (`pminsw`/`pmaxsw`): the sort alone measured 12.5 vs 26.9 ns at SSE2.
* **Evidence.** Prototype in this session's scratchpad (`mergebench/bench.cpp`; rebuild from
  this description — it copies the blocked kernel verbatim and adds the variant). 400
  randomised trials × 5 thresholds — full range, 4-value ranges, zeros mixed in, saturated,
  equal runs, random coverage misses: **3,072,000 pixel-channels, 0 differ**. Real 9-source
  24 MP band: 0 differ; fallback 0.005% of lanes, all-equal shortcut 0.5%. Single thread:

  | ISA | current | exact stats | speedup |
  |---|---:|---:|---:|
  | SSE2 (shipped x86) | 80–109 ns | 72–118 ns | 0.9–1.1x |
  | SSE4.1 | 92.9 | 75.3 | 1.2x |
  | **AVX2** | 86.5 | **40.9** | **2.1x** |

  Exact statistics only pay with a wider ISA; the dispatch is the point.
* **Win.** ~48% (GUI) / ~29% (cli) of merge CPU × (1 − 1/2.1): **14–25% of the merge phase**
  on x86. Arm64 unmeasured.
* **Verify.** The `#include`-the-real-`ImageAligner.cpp` differential harness (project memory
  `merge-step-cost-breakdown`): full 24 and 42 MP frames, 9 and 17 sources, 8- and 16-bit,
  both `includeAll` values, the randomised sweep above; then a 20-frame cli `cmp` A/B.

### R3 — Exact SIMD 16-bit warp, analytic coverage, row ranges (identical, 2–3 days)

* **What.** Replace `warpInto`'s CPU branch (`ImageAligner.cpp:2786`) and the cloud stage's
  `cv::remap` calls (`:4070–4072`) for 16-bit 1- and 3-channel data with code that reproduces
  OpenCV bit for bit: `WarpPerspectiveInvoker`'s fixed-point map generation, the same float
  interpolation table, the same left-to-right `S0·w0 + S1·w1 + S2·w2 + S3·w3` in float,
  `saturate_cast<ushort>`, and `BORDER_TRANSPARENT`'s skip rule. No per-block heap
  allocation. Vectorise over pixels. Take a destination row range (R4 needs it).
* **FP contraction.** Compile that file with `-ffp-contract=off` on x86, and on arm64 match
  whatever the vendored OpenCV was built with (it may contract into FMA there); the identity
  test decides.
* **Coverage.** `warpCoverage` warps a 255 plane per neighbour only to learn where the warp
  lands, and the cloud stage remaps a probe per neighbour for the same reason. Derive it from
  the integer maps instead: a pixel is covered iff every bilinear tap with non-zero weight is
  inside the source. This is S16, done exactly.
* **Win.** 52% (cli) / ~30% (GUI, warps + cloud remaps) of merge CPU; at 2–3x on the 16-bit
  path, removing the malloc churn and the probe warps: **25–35% of the cli merge phase**
  (*estimate*).
* **Verify.** Byte-compare against `cv::warpPerspective`/`cv::remap` over 1,000+ random
  near-identity and real stored homographies (`homography.db`), with coverage edges, on both
  architectures. One differing pixel is a failure.

### R4 — Merge only the rows the composite reads (identical for final frames, 2–3 days after R3; one decision)

* **What.** The final frame — and the subtraction image in outlier modes
  (`FrameAirplaneRemover.swift:2110–2160`) — is `skyImage.blend(mask: feathered, with:
  earthImage)` with `feathered = starAlignedMask.raiseMaskBy(24)`. Where the mask is 255 the
  earth pixel is unused; where it is 0 the sky pixel is. Compute the feathered mask first (it
  needs only the homographies and the horizon) and derive each merge's row range from it,
  exactly:
  * earth merge: from the first row where the mask is < 255, to the bottom;
  * star merge: from the top to the last row where the mask is > 0, **plus the cloud stage's
    `kRegionMargin` (300)** so its blurs read the same pixels.
  Check the blend's arithmetic returns exactly the sky value at 255 and the earth value at 0.
* **Win.** *Estimate* for a9-3 (horizon at rows 3,090–3,250 of 4,000): earth merge to ~24%
  of the frame, star merge to ~89%. The two base merges are about equal and together ~56% of
  the GUI's merge CPU, so **~25% of the merge phase**. The static 17-source earth merge
  (`FrameAlignmentProcessor.swift`, the `!config.tripodHeadWasMoving` branch) saves more.
* **Needs R3.** `cv::warpPerspective` cannot do a row sub-range bit-identically (translating
  the homography changes the rounding of each row's coordinates).
* **Decision for Brian (Q1).** The star-/earth-aligned intermediates (previews always,
  full-size files in outlier modes) would no longer be full merges outside their band.

### R5 — Horizon consensus without decoding every mask (identical, 1 day)

* **What.** `HorizonConsensusOp.detectedLines` (`HorizonConsensusOp.swift:380`) decodes each
  frame's full-resolution `.horizon` mask (24 MB, LZW) only to run `extractHorizonY` and make
  a grid line. Write that line when the mask is written (detection already has it in memory)
  as a small per-frame sidecar or a `homography.db` table, and read it, falling back to the
  mask when it is missing or stale. Key it on the mask file (size + mtime or a digest) so an
  edited mask invalidates it.
* **Win.** **2–4 min of serial, CPU-idle time per run at Full; 10 min under Light.**
* **Verify.** `HorizonConsensusStore` output byte-identical with and without sidecars on a
  full sequence.

### R6 — Match each neighbour pair once (identical, 2 days)

* **What.** On moving sequences each frame's homography op matches against ±1…±4, so every
  unordered pair is matched twice: `knnMatch(B→A)` in A's op and `knnMatch(A→B)` in B's. Both
  are the 2-nearest along the rows or the columns of the same distance matrix, and OpenCV's
  L2 and Hamming distances are symmetric bit for bit. Compute the matrix once per pair,
  derive both directions with OpenCV's tie rule (lowest index wins), and hand the reverse
  result to the other frame's op through a small cache keyed by (pair, type).
* **Win.** Half of 16.1%: **~8% of phase A**.
* **Verify.** Identical `DMatch` lists for both directions over a full sequence's pairs, and
  an identical `homography.db`.

### R7 — Pyramid readback without the copy (identical, 1 day)

* **What.** `matWrapper(fromReadback:)` (`GPUOps.swift:1674`) allocates a Mat and `memcpy`s
  each level out of the pooled readback buffer, single-threaded: ~1.4 GB per sky op at divisor
  1.5 (`firstOctave = -1`). Instead make the readback buffer the Mat's storage (a `cv::Mat`
  over external memory, owned by a `MatWrapper` with a release callback) and give the buffer
  back to the pool when the wrapper is released. Keep the `autoreleasepool` around
  `contents()` (project memory `gpu-inner-pointer-autorelease-leak`).
* **Win.** 8.1% + 1.7%: **~10% of phase A**.
* **Watch.** Pool sizing: levels now live as long as the SIFT tail reads them. Measure footprint
  with that memory's `findFeatures` harness, on this Vega and on Apple Silicon.
* **Later.** DoG and the extremum scan on the GPU would remove most of the SIFT CPU tail (14%)
  too; only after R7.

### R8 — Smaller phase-A items (identical, 1–2 days)

* **AKAZE port keypoint maps** (`AKAZEDetector.cpp:457–550`): four passes over every pixel of
  every evolution level through out-of-line `at<uchar>`, for maps that are almost all zero —
  5.1% of phase A. Keep a sparse row-major list of `(y, x)` per level and walk that; keep the
  order and it is identical.
* **Earth gradient mask** (`createGradientMaskIntoSky` → `distanceTransform`): built per earth
  keypoint op from the same horizon mask the composite's `raiseMaskBy` uses. Cache per frame.
* **`StarAlignedHorizonMaskCache`** (`StarAlignedHorizonMask.swift`): one process-wide actor
  that runs 8 full-frame NEAREST mask warps per frame. It only ever hits on static sequences;
  on moving ones it serialises that work for the whole merge phase. Compute outside the actor
  when the key cannot repeat, and time a call: its wall time per call caps merge throughput.

### R9 — Cloud stage (identical, 2 days; after R2/R3)

R2 and R3 cover its median (26% of the stage) and remaps (63% of its layer building). Left:

* the map lambda (`ImageAligner.cpp:4046–4068`, 8.2% of the GUI merge phase): a bilinear field
  and a homography in `double` per pixel. Vectorise with the same operation order, or emit
  R3's integer maps directly;
* `lowPass` and the box blurs (6%): separable passes over the region — check whether the
  algorithm allows them at the low-res grid;
* **Apple Silicon.** Once star and earth merges run on the GPU there, this CPU-only stage is
  the merge phase's CPU floor. Port its stack (remap + median) onto the existing Metal merge
  kernel; measure on the Mac Studio, not here (memory `apple-silicon-mac-studio-plans`).

### R10 — Scheduling and diagnostics

* **Stall watchdog.** When no op changes state for 60 s while gates hold slots, log which ops
  hold which gates and the process state. §1.2's freeze cannot be diagnosed from today's log.
* **Hyper-threads.** At Full the CPU gate is 18 (physical cores) and star keeps ~20–26 of 36
  logical CPUs busy. Measure a Custom CPU width of 24 and 36 on the merge phase, frames/min
  over 10 min, back to back (`perf-measurement-noise-floor`); make Full whichever wins.
  **Measured (6.3): neither wins; Full stays at 18.**
* **Ledger in the merge phase.** *(Withdrawn, see 6.3.)* As first written: footprint 3–6 GB
  against a 107–109 GB ledger on the CPU path, 20–30x over. Measured with `--log-op-memory`: a
  merge reserves 1.9 GB and ~18 running merges peak at 20 GB of footprint against 34 GB reserved;
  the rest of the ledger is queued ops' reservations. The estimate stands.
* **Light is not light in merges.** The probe at `--use light` (CPU width 4) ran at ~950% CPU
  during merges: each op's `parallel_for_` fans out regardless of the gate. Worth knowing
  before promising users Light leaves the machine alone.
* **Phase overlap (later, changes output at window edges).** Merges wait for validation and
  consensus over the whole sequence, though both are windowed in nature. Per-window
  validation/consensus would start merges while phase A finishes. Only after R5.

## 3. Not proposed

* `mergeLoadConcurrency`, the streaming threshold, OpenCL, the ANE: measured and rejected
  before (`merge-step-cost-breakdown`, `merge-streaming-threshold-cost`,
  `gpu-acceleration-survey`, `apple-silicon-mac-studio-plans`).
* Decode work: 0.7–0.8% of the merge phase. `DecodedFrameStore` did its job.
* Exact integer statistics *without* the near-tie fallback: changes output (4 samples in
  126.5M, max delta 26,368; comment at `ImageAligner.cpp:422`). R2 keeps the fallback.
* Random Walker solver speed (S15), FLANN or GEMM matching: output-changing; they stay on
  `CODE_REVIEW_PROPOSAL.md`'s A/B list. R6 is the identical part of matching.
* The GUI main thread redrawing `AlignmentDeviationChart` during processing (3.4%): real, but a
  client item.

## 4. Working on this

* **One heavy job at a time** (memory `one-heavy-job-at-a-time`). The user runs long GUI jobs
  here; check `ps` before a cli run, a test suite or a build, and use `--use light` plus `nice`
  for profiling runs.
* **Measure kernels, not runs.** End-to-end wall clock has a ~90 s noise floor
  (`perf-measurement-noise-floor`). Use min-of-K single-thread kernel timings on real frames,
  and CPU-seconds for runs.
* **Profiling.** `sample <pid> 10 -mayDie -file …` in a loop. Attribute by the kernel's own
  symbol (`medianMergeTyped`, `WarpPerspectiveInvoker`, `RemapInvoker`,
  `__func<cloudAwareRefine`, `cloudaware::`, `gaussSeidel`, `FilterBilateral`,
  `findScaleSpaceExtrema`, `normL2Sqr`, `normHamming`, `LZWEncode`), then walk callers of a
  leaf such as `_platform_memmove`. Beware Swift frame names: `findFeatures(…useGPUForAKAZE:)`
  contains "AKAZE", so a substring rule on "AKAZE" sweeps in all keypoint work.
* **Worktree build.** Symlink `opencv/{include,lib,opencv2.framework}`,
  `StarDecisionTrees/{include,lib}` and `external_binaries/bin` from the main checkout, then
  `cd cli && swift build -c release -j 8` (~8 min cold). The cli Xcode project does not link
  (`cli-xcodeproj-ld-broken`). For R1, the GUI's flags are in
  `gui/DerivedData/…/Objects-normal/<arch>/*common-args.resp`.
* **Identity.** Kernels: the `#include`-the-real-`.cpp` harness. Runs: 20 frames through the
  cli, `cmp` every output; `magick compare -metric AE` when they differ.
* **Both clients.** R1 is GUI-only by nature. Everything else is StarCore/StarCpp and reaches
  the daemon and the Kotlin client unchanged; nothing here is user-facing, so CLAUDE.md's
  "Swift and Kotlin change together" has nothing to mirror.

## 5. Questions for Brian

1. **R4.** *(Answered 2026-10-30: base-frame pixels, automatic mode only.)* With band-limited
   merges, what should the star-/earth-aligned intermediates show
   outside their band: base-frame pixels, or a full merge built on demand when viewed?
2. **R2.** Is runtime AVX2 dispatch acceptable in the shipped x86 binary? Every Intel Mac
   that runs macOS 13 has AVX2; the Windows/Linux daemon builds would dispatch at runtime too.
3. **GPU merges** are off in your prefs on this Vega. Permanent until the Mac Studio? If so,
   R2–R4 and R9 are the merge phase's speed for now.
4. **Output compression.** *(Answered 2026-10-30: adaptive — uncompressed unless LZW takes a tenth
   off. Built; see 6.1.)* LZW on the final TIFF is 12.7% of the cli's merge CPU and saves
   0–8% of disk on this data. Keep it, make uncompressed an option, or change the default?
   *(Measured 2026-10-30, 6.3: 15.1 % of the merge phase over a whole run, and on a9-3 the
   LZW file is 148 MB against 144 MB uncompressed — larger, not smaller.)*

## 6. Implementation log (2026-10-29, branch `claude/core-speed-proposal-8df3ba`)

What was built from sections 2 and 4, how it was held to "identical", and what was left. Every
speed figure below is single-threaded on this iMac Pro with its own user's GUI job running
beside it (load average 50–70), so read the *ratios*, not the nanoseconds; CPU-seconds from the
end-to-end A/B are in 6.3.

### 6.1 Done

| item | where | held to identical by |
|---|---|---|
| **R1** StarCpp at `-O2` in the GUI | `StarCpp/Package.swift`, `optimizationCXXSettings` (`.when(configuration: .release)`) | Xcode's own response file for `StarCpp.build/Release/…/*common-args.resp` now has `-Os` at argument 10 and `-O2` at 34; clang takes the last. (`-O3` was no better than `-O2` on the old median kernel.) |
| **R2** median kernel | `StarCpp/Sources/StarCpp/MedianMerge.hpp` (moved out of `ImageAligner.cpp`, Welford kernel verbatim as `mergeRowsWelford`) | `bench.cpp` harness: the pre-change kernel textually renamed beside the shipped one, 3,000+ random shapes × both depths, 1/3 channels, 2…65 sources, both `includeAll`, honest and garbage coverage, exact-tie data: **0 differ**; real 24 MP bands (9 and 17 sources, holes down one edge) **0 differ**; ASan + UBSan clean; mutation tests (band removed, fallback removed) fail as they should. In the suite: `MedianKernelEquivalenceTests`. |
| **R3** exact 16-bit warp + analytic coverage | `StarCpp/Sources/StarCpp/ExactWarp.hpp`, used by `warpInto`, `warpCoverage` and the aligned merge's `warpNeighbour` | `warpbench.cpp` against `cv::warpPerspective` and the 8-bit probe warp: 93 M pixel-channels, identity / integer and fractional shifts / near-identity fits / rotation / strong perspective / mirror / zoom / half-pixel and 32nd-exact positions / degenerate W=0, 1–1200 px wide, 1 and 3 channels, scalar and AVX2 rows: **0 differ, 0 coverage differ**; ASan + UBSan clean. In the suite: `ExactWarpEquivalenceTests`. |
| **R5** consensus from line sidecars | `StarCore/Sources/StarCore/HorizonLineSidecar.swift`; written by `ImageAccessor.saveInt`, read (and healed) by `HorizonConsensusBuild.detectedLines` | `HorizonConsensusTests`: sidecar columns equal `extractHorizonY` of the reloaded mask; a rebuilt consensus from sidecars equals the one from masks; a mask rewritten or resized invalidates its sidecar. |
| **R8** AKAZE keypoint-map scans | `AKAZEDetector.cpp`, `forEachNonzero` | `akazebench.cpp`: old and new passes over random multi-octave level sets (three densities), 270 k keypoints compared bit for bit, **0 differ**; the passes themselves 1.75× at 24 MP scale. |
| **R8** `StarAlignedHorizonMaskCache` | `StarAlignedHorizonMask.swift` | Same computation, off the actor on the CPU gate, with single-flight for equal keys; `StarAlignedHorizonMaskTests` (counters unchanged for sequential use, new test for concurrent asks). |
| **R9** cloud stage: map lambda + float-map `remap` + coverage probe | `ExactWarp.hpp` (`remap`, `remapField`, `DisplacementField`, `fieldMapsAvx2`), used by `buildLayer` in `cloudAwareRefine` | `remap_bench` against `cv::remap` (16-bit, 1 and 3 channels, destination size independent of the source's) and the 8-bit probe remap: float maps of ten kinds including exact ties in 32nds, NaN / inf / ±3.4e38, far outside, hugging the frame — 34 M pixel-channels, **0 differ, 0 coverage differ**; random displacement fields (random homography incl. W≡0 and W crossing 0, grids from 1×1 up, regions that do not start on a multiple of 8): 611 M map floats compared **bit for bit** with the stage's lambda, copied verbatim, and 637 M pixel-channels through `remapField` against lambda + `cv::remap` + probe `cv::remap`, **0 differ**. Five mutations of the kernel each fail the sweep (half-up instead of half-even rounding, scalar and AVX2; lerp form of the field blend; no degenerate-W fallback; no last-row renormalisation). In the suite: `CloudAwareMergeTests.testTheExactRemapMakesTheSameMerge` (also fails when the AVX2 rounding is broken). |
| **R9** cloud stage box blurs | `StarCpp/Sources/StarCpp/BoxBlur.hpp` (the stage's `boxBlurOnce` moved out of `ImageAligner.cpp`, original arithmetic kept as the scalar form) | `blur_bench` against a verbatim copy of the original: 21.8 M elements over widths/heights 1…600 (including narrower than the window), radii 1…48, both scales, luma-sized / weight-sized / signed / NaN / ±inf / ±1e30 / exact-tie values, bitwise, scalar form and AVX2 form: **0 differ**. Mutations that fail it: round toward zero, NaN not zeroed, wrong right-edge padding. (One that does *not*: multiplying by `1/norm` instead of dividing — double rounding differs too rarely for random data to see, so the division stays by construction.) Same hook as R3 (`STAR_WARP=opencv` / `debugSetExactWarp`) selects the scalar form, so `testTheExactRemapMakesTheSameMerge` holds the blurs to it inside a whole merge. |
| **R9 follow-up** `interpolateBlockAvx2` eight pixels at a time | `ExactWarp.hpp` (`interpolateBlockAvx2` over `interpolateRangeAvx2`, `bilinearTable3`) | The bilinear loop every warp and cloud-layer pixel goes through, and the largest single symbol in the merge-phase profile (19.9 %). For three-channel frames, eight pixels whose windows are all interior (and not on the second-to-last row, so a 16-byte load cannot leave the frame) get their offsets and weight-table indices in registers; each pixel is two 16-byte loads, one multiply per row against a laid-out weight pair, and the same left-to-right sum, `((p0+p1)+p2)+p3`, with p1/p3 moved from lanes 3–5 to 0–2 first. Anything else goes through the old per-pixel code. `warp_bench` 92.9 M pixel-channels and `remap_bench` 54 M + 1.07 G, **0 differ, 0 coverage differ**; mutations that fail: sum order changed (153 of 13 M pixels differ — the sensitivity this needs), no coverage store, interior test one row too generous. |
| **R6** match each frame pair once | `StarCpp/Sources/StarCpp/PairMatch.hpp`; `knn2` replaces the two `matcher.knnMatch(descNeighbor, descBase, …, 2)` calls in `computeHomography` | Read from `batch_distance.cpp` and `BFMatcher::knnMatchImpl` (4.12.0): a distance is `sqrt(hal::normL2Sqr_(a, b))` (float L2) or `hal::normHamming` (packed bits) — symmetric in its arguments to the bit — and a row's answer is its two smallest under (distance, index) by strict-`<` insertion on the integer bit pattern, a distance at or above FLT_MAX/INT_MAX never chosen. One pass over the matrix gives A's op its rows and B's op its columns; the first op to ask computes both and leaves the other direction (16 bytes per row, 128 MB cap, oldest out first) under a key made of the *content hash of the two descriptor sets*, which the partner's op takes. `match_bench` against `cv::BFMatcher` in both directions: 72 M descriptor pairs (SIFT-like float 128-d, quantised floats with many equal distances, all-equal rows, sums that overflow to infinity, packed bits with few distinct distances, 1…1,200 rows a side): **0 differ**; five mutations fail it (tie to the higher index, no sentinel, only the first chunk merged, Hamming distance off by one, wrong cache key); ASan/UBSan clean. In the suite: `PairMatchEquivalenceTests` (the same sets through `knn2`; and a sky alignment of a pair of rendered star fields both ways, in both orders, with the cache's count asserted to go 1 → 0 and the homographies equal to the numbers with the sharing off). A 60-frame cloudy a9-3 run (frames 157–216, Full, both sky and earth, so L2 and Hamming), BFMatcher against the pair matcher: all **120 stored homographies** (decoded) and all **60 output frames identical**. |
| **Q4** adaptive TIFF compression (answered 2026-10-30) | `MatWrapper.cpp`, `lzwWorthIt` in `mat_wrapper_write_to` | A TIFF of 8 MB or more is written uncompressed unless LZW takes a tenth or more off, judged by the file's own encoder on 32 evenly spaced rows (`cv::imencode(".tiff")`, one row a strip as the file would be, a row's compressed size being independent of its neighbours); `STAR_TIFF_COMPRESSION=lzw` / `none` forces either. Smaller files, and the 8-bit masks, keep LZW. Pixels are untouched: 30 merged 24 MP frames of a9-3, LZW against adaptive, **0 differing pixels in all 30** (`magick compare -metric AE`); the same frame written twice is byte-identical. `TiffCompressionTests` (noise → uncompressed and exact; smooth gradient → LZW and exact; 8-bit mask → LZW; small noisy frame → as before; the environment override), the TIFF direct-read tests unchanged. |
| **R4** band-limited earth merge (Q1 answered 2026-10-30: base-frame pixels outside the band, automatic mode only) | `Config.bandLimitedEarthMerge` (on); `createAutoProcessedImage` makes the star-aligned mask and its feathered form first, `ImageAligner.firstRow(of:below: 255)` gives the first row the blend can read the earth at, and `loadOrCreateEarthAlignedImage(rows:)` passes it to the moving camera's aligned merge (`alignAndMergeBand`, `exactwarp::warpBand`) or the static camera's median (`ia_median_merge_image_with_filenames(rowStart,rowEnd)`) | The blend copies the sky whole where the feathered alpha is 255 and computes `sky·w + earth·(1−w)` in float elsewhere, which is exactly the sky at w = 1, so no earth row above the first one holding a value below 255 is ever read (and the hard-mask fallback needs a subset of them). `FeatheredCompositeTests.testTheEarthAboveTheMasksFirstRowBelow255IsNeverRead` replaces those rows with garbage and requires the composite unmoved through both blends (merging 3 rows too few fails it). `ExactWarpEquivalenceTests`: for bands from the top, to the bottom, one row and the whole frame, 1 and 3 channels, neighbours with missing homographies, the exact warp off, and (static) a source of another size, every band row is the whole merge's row and every other row the base's (breaking the band's coverage counts fails it with 50 errors). **Real footage:** a9-3 moving, 30 frames: engaged on all 30 (earth rows 3,069–3,115 → 4,000, 23 % of the frame), final frames **byte-identical** on against off in two independent pairs; fx3 static 12 MP dusk, 60 frames: engaged on all 60 (≈2,300 → 2,832, 19 %), final frames byte-identical in four pairs. **CPU is not resolved** (moving: 1,372 and 1,151 CPU-s off, 1,113 and 1,048 on; static, eight runs: 1,134–1,614 off, 1,050–1,761 on — the runs differ from each other by more than the effect), and the payoff is **far below section 2's ~25 %**, which was written before R2, R3 and R9: the earth merge is now roughly a tenth of the merge phase (its eight warps and one of three median stacks), so skipping three quarters of its rows is worth something like 5–8 % on a moving sequence and less on a static one, whose 17-source median the R2 kernel made cheap. Only the earth-aligned *previews* change: above the band they show the original frame. A GUI request for the aligned image, outlier modes, the GPU merge and the streaming path all merge whole; a band-limited image is never written at full size. |
| **R10** stall watch | `StarCore/Sources/StarCore/StallWatch.swift`, called from `ResourceGovernor.tick` | `StallWatchTests`. |

Two facts worth keeping from reading OpenCV 4.12.0's `imgwarp.cpp` (the tree has it at
`opencv/opencv/`), because section 2 R3 had them slightly differently:

* **BORDER_TRANSPARENT touches a pixel iff its floor coordinates are inside the source
  (`0 ≤ sx ≤ w−1`, `0 ≤ sy ≤ h−1`).** Pixels strictly inside (`sx < w−1`, `sy < h−1`) are
  interpolated; the last column and row are interpolated from the corners that exist and
  rescaled by `Σw_all / Σw_present`; a pixel that floors to −1 is left alone even though one of
  its corners is real. The weights present can never sum to 0, so "touched" is a function of the
  integer maps alone — which is why the 8-bit probe warp of `warpCoverage` can be replaced by a
  pass over the maps, and why S16's "every tap with non-zero weight is inside" is not the rule.
* **The coordinates are not a function of the pixel alone.** `warpPerspective` walks the
  destination in blocks `min(1024 / min(16, rows), cols)` wide from column 0, each row of a block
  starting from `M0·x + M1·y + M2` at the block's first column and adding `M0·x1`. Rows do not
  matter (each starts from its absolute y), so a row range is exact — what R4 needs — but the
  block width has to be OpenCV's. The runtime path on x86-64 is the SSE4.1 line generator,
  separate multiplies and adds in double with no FMA, which is also what the scalar tail does.
  On arm64 OpenCV uses fused multiply-adds there, so the exact warp is x86-64 only
  (`STAR_EXACT_WARP`) and arm64 keeps `cv::warpPerspective`; the GPU merge is the default
  there anyway.

Kill switches, for an A/B on a real run in one binary: `STAR_MEDIAN_KERNEL=welford`,
`STAR_WARP=opencv` (R3 and R9), `STAR_REMAP=opencv` (R9 alone). All are read once. The tests flip the same switches in-process
(`ImageAligner.debugSetMedianKernel`, `debugSetExactWarp`).

R2's kernel is compiled for AVX2 and chosen at run time (CPUID + XCR0, no `__builtin_cpu_supports`),
on x86-64 only; everything else, and `k` outside 0…1e6, runs the Welford kernel unchanged.
So Q2 was answered "yes" in code — it is one `if` in `mergeKernelForThisMachine` to say no.

### 6.2 Measured (single thread, loaded machine)

| | before | after | ratio |
|---|---|---|---|
| median kernel, 9 sources, 3 ch, real 64×6000 band | 124 ns / pixel-channel | 18.6 | **6.7×** |
| median kernel, 17 sources | 191 | 26.7 | **7.2×** |
| the same old kernel at `-Os` (what the GUI ran) vs `-O2` | 155 / 467–598 ns (9 / 17) | 107–129 / 166–251 | 1.2–2.8× — the 17-source static merge was hit hardest |
| 16-bit warp + its 8-bit coverage probe, 6000×1000×3 | 21.6 + 36.3 ns/px | 17.7 (scalar), 7.3 (AVX2), one pass | 1.9× scalar, 2.2–5.4× AVX2 |
| cloud stage layer: map lambda + `cv::remap` 16-bit + 8-bit coverage probe → `remapField`, 6000×1000×3 region, smooth cloud field | 8.2 + 4.3×3 + 5.3 = 26.3 ns/px | 8.3 (AVX2), 17.2 (scalar rows) | **3.2×** AVX2, 1.5× scalar; 2.6× on a noisy ±100 px field |
| descriptor match of one pair, both directions, 8,000 × 8,000 SIFT-like descriptors | two BFMatcher passes 0.19–0.20 s | one pair pass 0.11–0.12 s | **1.6–1.7×** for the pair; a pair's partner op then skips its match, so about half the matching CPU goes (hit rate on the 60-frame run: 341 of the first 800 matches, 43 %, the rest being sequence ends and partners still in flight) |
| merge-only rerun of 30 cloudy 24 MP frames, final TIFF LZW → adaptive (uncompressed) | 1,391 and 1,361 CPU-s (81.6 and 76.0 s wall); files 149.4 MB | 1,262 and 1,279 CPU-s (61.9 and 63.4 s); files 144.0 MB | **−8.6 % CPU, −21 % wall**, alternating runs, both repeats agree; the file is 4 % *smaller* |
| bilinear loop alone: warp + coverage, 6000×1000×3; cloud remap | 2.5–2.7 ns/pc; 8.7–9.0 ns/px | 2.1–2.4; 7.5–7.6 | **1.15–1.2×**, alternating runs. The count of the code (45 µops a pixel → ~30) said 1.5×; the loop is not simply issue-bound, so what it bought is 15–20 % of a kernel that was a fifth of the busy samples |
| cloud stage box blur, one pass, 6000×3400 plane (r = 6 and 24) | 6.6–6.8 ns/element | 3.3 (3.1–3.4 at strips of 256–512 columns) | **2.0×** (1.6× with the original 64-column strips: the column pass reads a column band down 24 KB-apart rows, so a wider strip is longer runs of the same cache lines) |
| AKAZE map passes, 24 MP-scale levels | 0.754 s | 0.431 s | 1.75× (the dense extremum scan, unchanged, is most of what is left) |

A first, autovectorised version of the exact-statistics idea measured 1.4–1.9× here, in line with
section 2 R2's 2.1×; the register kernel (sorting network and block held in YMM registers per
source count 2…17, exact sums in double, integer bounds counted in 16-bit lanes) is what gets to
~7×.

### 6.3 End-to-end identity and CPU

Probe: frames 645–674 of a9-1 07_11 (30 × 24 MP, moving), release cli built from this worktree and
from a pristine checkout of `develop` at `05d8c1b7`, `--use light --moving-camera --no-use-gpu
--cloud-aware-merge --keep-temp-files`, `nice 10`, the painted reference linked in as in section
1.1, the machine otherwise idle. (Light, so the CPU gate is 4 wide and wall clock is gate-limited;
read CPU-seconds.)

| run | wall | user | sys | CPU-s | peak footprint |
|---|---:|---:|---:|---:|---:|
| baseline binary | 324 s | 1,628 | 245 | 1,873 | 13.1 GB |
| new binary, `STAR_MEDIAN_KERNEL=welford STAR_WARP=opencv` | 327 s | 1,603 | 248 | 1,851 | |
| **new binary** | **254 s** | **1,076** | 282 | **1,358** | 13.3 GB |

* **Identical.** All 30 output frames are byte-identical (`cmp`) between the baseline and the new
  binary, and between the baseline and the new binary with the switches on; so are all 150
  intermediate files kept with `--keep-temp-files` — SIFT and AKAZE keypoint files (the AKAZE
  map-scan change), horizon, merged-horizon and auto-processed images — and the 60 rows of
  `homography.db`, compared as parsed JSON (the encoder does not order keys, so the raw blobs
  differ between runs even though every value is the same).
* **−27 % CPU (−493 of 1,851 CPU-s), −22 % wall** end to end on this probe, which is 9-source,
  clear-sky, with the cloud stage nearly filtered out. The switch-off run says all of it is R2 + R3:
  R5 and R8 are on in both runs and cost nothing measurable on 30 frames. sys time rises by 34 s;
  not investigated. This run was not split by phase, so what is left of the merge phase's CPU
  (decode, the output TIFF's LZW encode — Q4 — OpenCV's other calls) is not measured here; profile
  a run (`sample`, section 4) before choosing the next item.
* Section 1.3's GUI profile, where the median kernel was 48.6 % of busy CPU at `-Os`, should gain
  more than this cli probe did; that has not been run (it needs the GUI build and a cloudy
  sequence).

A 30-frame sequence is too short for the horizon consensus to calibrate (it needs 36 and logs
"could not calibrate … keeping the merged horizons"), so R5 was checked separately on frames
645–692 (48 frames, `LRT_probe_a9_48`), same settings:

| run | wall | user | sys | CPU-s | horizon consensus |
|---|---:|---:|---:|---:|---:|
| baseline binary | 514 s | 2,656 | 414 | 3,070 | 7.8 s |
| new binary | 408 s | 1,693 | 497 | 2,190 | 4.8 s |

All 48 outputs, all 288 other kept files and the 96 `homography.db` rows are identical (as in
the 30-frame run), and so are the 49 files in `horizonConsensus/` (47 lines, the calibration and
one more), compared as parsed JSON; the new run wrote 47 sidecars and read them. The consensus
step is 3 s shorter on 48 frames, which is 62 ms a frame — the decode that section 2 R5 removes —
so the serial gap per run scales as that times the frame count (the section's 124–218 s at
1,300–2,100 frames); not measured at that size. CPU −29 %, wall −21 %.

#### R9 on cloudy footage

The first probe is mostly clear sky, where the cloud stage is pre-filtered out, so R9 got its own:
frames 157–186 of a9-3 (05_16, dusk, thick moving cloud), 30 × 24 MP, moving, same release cli and
flags (`--use light --moving-camera --no-use-gpu --cloud-aware-merge`). The stage ran on all 30
merges, on a region of about 6000×3400 of the 6000×4000 frame.

* **Identity.** The new remap against `cv::remap` in one binary (`STAR_REMAP=opencv`): all 30 output
  frames and all 30 `auto-processed` merges byte-identical; of the 182 other kept files, the only
  differences are logs, SQLite `-shm`/`-wal`, and the mask-mtime field in the header of the R5 line
  sidecars (the columns are identical). The same 30 outputs came out of every later run, including
  the one with the AVX2 box blurs in the binary (`STAR_WARP` unset): 30/30 identical to the
  `cv::remap` run's.
* **CPU is not resolved at this size.** Whole run, `cv::remap` → exact remap: user 1,928 → 1,815 s,
  sys 437 → 461 s (−3.8 % of the total), wall 324 → 330 s. Merge stage only (copy the finished temp
  dir, bump `cloudAwareMergeAlgorithmVersion` so only the merges rebuild, two alternating pairs):
  user+sys 1,689 → 1,584 s and 1,948 → 1,929 s. The same variant repeated differs by up to 15 %
  (1,360 vs 1,557 user-s), more than the effect, so these say "no worse, plausibly 4–6 %" and no
  more. What is known: the layer-building step alone is 3.2× (6.2), and at 8 layers × a 20 M pixel
  region it was about 4 CPU-s of a ~45 CPU-s merge, so ~6 % is what to expect; the box blurs, 2×
  on 13.7 % of the busy samples, another ~7 %.
* **What the merge phase looks like now** (25 s `sample` of the cli, all threads, after R2/R3 and the
  R9 remap, shares of busy samples): `exactwarp::interpolateBlockAvx2` 19.9 %
  (the shared bilinear loop, star warps and cloud layers), `madvise` 8.8 %, the R2 median kernel
  8.4 %, the two box-blur passes 13.7 % (before the blur work), `fieldMapsAvx2` 5.3 %,
  `cv::OcvDftImpl::colDft` 4.5 %, `lumaDownRows` 4.2 %, `cv::hal::integral` 2.6 %, `medianBlur`
  2.1 %. System time was 584 s against 1,624 s user (26 % of the CPU in the kernel). Two things in
  it are not R9: **`madvise` is the free of `matchTemplate`'s DFT temporaries in the velocity search**
  (`measureGrid` → `matchTemplate` → `~Mat` → `free_medium` → `madvise(MADV_FREE)`), i.e. the per-tile
  search allocates and returns tens of MB per call and pays page faults to get it back;
  and `colDft`/`integral`/`mulSpectrums` are that same search's arithmetic (~10 %). Pooling those
  buffers (or one `matchTemplate` per tile row on a shared scratch) is the next thing this profile
  points at, and it is independent of everything above.
* The sample taken after the blur change reads the same kernels at different shares (it landed in a
  different part of the merge), so shares across the two samples are not a measurement of the blur.
  The blur's 2× is the harness's.

#### R10 measurements (2026-10-30)

Probe: frames 157–246 of a9-3 (90 × 24 MP, moving, cloud stage on), the finished temp dir copied for
each run, the cloud-aware merge version bumped so only the merges (and what follows) rebuild, resumed
from `config.json` as a Custom profile with Full's pipeline depth of 72 and the CPU gate width set.

* **Hyper-threads: no win; Full stays at the physical-core count.**

  | CPU gate | wall | user + sys CPU-s | gate slots in use (avg) | peak resident |
  |---|---|---|---|---|
  | 18 | 334 s, 372 s | 5,357, 5,835 | 12.6–13.0 | 54.5–55.6 GB |
  | 24 | 321 s | 5,525 | 14.9 | 65.5 GB |
  | 36 | 476 s, 381 s | 6,820, 6,033 | 23.0–24.8 | 73.6–76.1 GB |

  The same width differs by 10 % between repeats, so 24 cannot be told from 18, and 36 is no faster
  and spends more CPU (once 1,864 s of system time). The governor's own reading at every width is
  "limited by disk" in 30–50 % of its samples (the rest "by CPU"), which fits a volume that does not
  read faster for more merges at once — each reads its base and eight neighbours — though the disk
  was not measured on its own. The memory fraction was raised for the wider runs but
  `maxMatMemoryFraction` is capped at 0.95 (ledger peak 122–123 GB), so these runs were not free of
  the ledger — but the ledger is not what held them back (next item).
* **The ledger's merge estimate is about right; the "20–30× over" in section 2 R10 is withdrawn.**
  `--log-op-memory` on the same merges: each reserves **1,922 MB** (1,647 near the ends of the
  sequence) — 13 × a 148 MB working frame — while the process footprint peaked at **+20.1 GB with
  ~18 merges running**, i.e. 34 GB reserved against 20 GB used, 1.7× to spare. The ratio in section
  2 divided a footprint gauge, sampled at quiet moments, by the *whole* ledger, which at 107–109 GB
  is mostly the reservations of ops queued behind the CPU gate (72 deep × 1.9 GB); the gate, not
  the ledger, paces the running ones. The per-op lines' "OVER RESERVATION by 18 GB" is an artifact
  of the probe: each op's "peak" is the whole process's growth while it lived, so every overlapping
  merge prints the same 20,137 MB. No change to the estimate or the 0.25 floor on this evidence.
* **A 3½-minute silence in a Full run, cause not found.** The first 90-frame Full run logged nothing
  between 9:44:36 and 9:47:37 — no op, no governor line — then a `MemoryMonitor` line "forcing
  waiter 6 … waited 223 s", and the governor's first line since, in the same millisecond. The
  monitor polls twice a second, and the waiter's 60 s deadline fell at 9:44:54, so for the 160 s
  between that and the force the monitor was not running: the process (or all of its cooperative
  threads) was stopped from outside, or stuck in the kernel on `/Volumes/op` (the disk gate was
  full, 8 MB/s). A rerun with an external poller (process state every 2 s, a `sample` when the log
  went 40 s quiet) never stalled — the longest quiet stretch was 30 s — so the cause is unknown.
  What was wrong in star is that its own stall watch stayed silent: the window averaged 2 % CPU
  (half a minute of work either side of the gap) and the rule wanted under 1 %. It now says "not
  running" under 10 % and, separately, "governor late" for a late sample the CPU was busy in;
  three new tests, one of them this run.

#### R6 on real footage

The 60-frame run above, BFMatcher against the pair matcher in one binary (`STAR_MATCH=opencv` turns
it off): identical stored homographies and output frames (6.1). CPU is not resolved: user+sys 4,338
and 3,871 CPU-s for BFMatcher, 4,074 for the pair matcher, runs that differ from each other by more
than that. The first pair of runs also shows what a cold page cache does to a comparison: 537 s the
first time the 60 frames were read from the volume, 248 s the second, with nothing else changed. The
saving to expect is what 6.2 says of the matcher's share, half of 16 % of phase A.

#### The merge phase over a whole run (2026-10-30, after R1–R3, R5, R6, R9)

A merge-only rerun of the 90-frame cloudy probe (a9-3 157–246, Full), `sample`d for 12 s every 25 s
for the whole run: 18 windows, 705 k busy samples, shares of those. This replaces the single 25 s
windows quoted in 6.3 above, each of which caught one phase of the merge and overstated whatever
ran then (box blurs read 13.7 % in one, 7.7 % over the run; `lumaDownRows` 4.2 % and 2.8 %, against
a measured 36 ms a 24 MP frame, ~0.5 % of a frame's CPU).

| share | what |
|---|---|
| 20.9 % | warp and remap interpolation (`interpolateBlockAvx2` 13.2 %, `warpRowAvx2` 3.7 %, and 3.4 % that is OpenCV's own NEAREST warp: the horizon-mask warps, `processNN` + `remapNearest`) |
| **15.1 %** | **`LZWEncode`** — the final TIFF (below) |
| 12.4 % | allocation, zero-fill and free (`bzero` 7.0 %, which includes the page faults of fresh buffers; `madvise` 2.0 %) |
| 10.5 % | the velocity search: `matchTemplate`'s DFT, integral images, spectra |
| 8.6 % | the R2 median kernel |
| 7.7 % | box blurs (after the AVX2 form) |
| 3.0 % | cloud map generation; 5.0 % luma / low-res / `medianBlur`; 2.7 % file I/O; 13.9 % thin spread |

**LZW on the final TIFF is the second-largest item and does nothing for the files.** The only file
the merge phase compresses is the final frame (the `auto-processed` image the output links to):
LZW with the horizontal predictor and one row to a strip. On this footage each comes out at
**148 MB against 144 MB for the uncompressed source frame** — three percent *larger* — because
night-sky noise does not compress. Q4 in section 5 is therefore sharper than it was written:
15 % of the merge phase's CPU for a file that is no smaller.

### 6.4 Not done, and why

* **R4** is done for the earth merge (6.1), moving and static. Not attempted: the *star* merge's
  band (skip the ground rows below the horizon plus the cloud stage's 300-row margin). It is the
  smaller half — about 10 % of that merge's rows — and unlike the earth band it sits under the cloud
  stage, whose noise sigma is taken from the base frame's sky alone (so unaffected) but whose error
  map, trusted region, blurs and relative test read merged rows across the sky and a margin; showing
  that 300 rows covers every one of those dependencies is an audit of the whole stage that has not been
  done, and the prize is a tenth of one merge.
* **R6** is done (6.1): the cache holds only the small 2-nearest results, is capped, and cannot
  return a stale entry because it is keyed on the descriptors' content. **R7** (pyramid readback without the copy) was left: it needs a `cv::Mat` over Metal
  readback storage with a release callback, and a pool that today recycles buffers the moment
  the copy is done would hold them for the life of every level — a memory-footprint change that
  has to be measured on the Vega *and* on Apple Silicon before it ships. Neither is worth doing
  without that measurement, and neither is blocked by anything here.
* **R8**'s earth gradient-mask cache — declined on measurement: `createGradientMaskIntoSky` is
  already the tuned form (its own comment: 308 ms a call at 42 MP, ~0.2 s at 24 MP) against
  ~60 CPU-s a frame, and the two uses take different gradient distances (100 and 24), so a cache
  would have to hold the 96 MB float distance map per frame across phases. Not worth it.
* **R9**: the map lambda, the float-map `remap` with its coverage probe, and the box blurs are done
  (6.1). Not done: `lumaDownRows` (4.2 % of busy samples; per-pixel float sums in a fixed order
  over 4×4 blocks of interleaved 16-bit BGR, so vectorising across pixels needs a deinterleave;
  not attempted), `medianBlur` (OpenCV's own,
  already AVX2), and the **Apple Silicon** port of the stack to the Metal merge kernel, which has to
  be measured on the Mac Studio. On arm64 the cloud stage keeps `cv::remap` and the scalar box blur
  (`STAR_EXACT_WARP` is x86-64 only), the same as the warps. And `interpolateBlockAvx2` got its eight-pixel form (6.1): 1.15–1.2×, less than a count of its µops promised.
* **R10**: measured (6.3) — no change to Full's width or to the ledger's merge estimate. The
  3½-minute silence is not explained; the stall watch's rule was the thing that could be fixed.
* **Q4** (LZW on the final TIFF) is yours.
