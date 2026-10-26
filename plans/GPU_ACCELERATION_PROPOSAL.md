# GPU Acceleration for `star` — Analysis and Proposal

Measured 2026-09-19 on the iMac Pro (Xeon W-2191B, 18 cores / 36 threads,
128 GB, Radeon Pro Vega 64 16 GB, macOS 15.8) against real 42 MP frames from
`/Volumes/rp/star_test/test_a7riiia_20-2` (7952x5304, 16-bit, 241 MB/frame).

---

## 1. Headline

The auto path's cost is concentrated almost entirely in three stages, and all
three are close to ideal GPU workloads. Measured, on this machine:

| stage | CPU today | Metal | ratio |
|---|---|---|---|
| SIFT Gaussian scale-space pyramid (sky keypoints) | **41,831 ms** wall / 29,672 core-ms | **183 ms** | **228x** |
| `warpPerspective` 16UC3, one neighbour | 117 ms wall / **3,076 core-ms** | **0.99 ms** | **118x** wall, 3100x core |
| sigma-clipped median, 9 sources | 2,940 ms wall / 9,100 core-ms | **100 ms** | **29x** wall, 91x core |

And two findings that reframe the problem:

1. **`cv::SIFT` is single-threaded and is ~100% Gaussian blur.** In a live
   profile of the auto path, `SIFT_Impl::detectAndCompute` was 50.4% of all
   samples, of which `buildGaussianPyramid` was 118,750 of 118,752 — i.e. the
   whole of it. Below that: `GaussianBlur` → `sepFilter2D` →
   `SymmColumnVec_32f` at 44.3% of the entire process. A separable float
   convolution over a scale-space pyramid is the single most GPU-shaped
   workload in image processing.

2. **OpenCL is a dead end on macOS; Metal is not.** The vendored OpenCV has
   `HAVE_OPENCL` and reports the Vega as a device, but the transfer path is
   catastrophically slow — 644 MB took **15.6 s** to upload (41 MB/s) — and the
   same pyramid through `cv::UMat` was *slower* than the CPU (55.9 s vs 41.8 s).
   Straight Metal moved the same 644 MB in **58.8 ms (11.5 GB/s)**. Do not
   plan around the OpenCV T-API.

---

## 2. Method, and what these numbers are and aren't

- Per-op costs come from standalone binaries linked directly against
  `opencv/lib/macos/libopencv2.a`, min-of-K on real frames, the instrument
  [[perf-measurement-noise-floor]] calls for.
- `core` is CPU-seconds from `getrusage`; `wall` is elapsed. **`core` is the
  number that matters.** A real run holds `numberOfFramesToProcessConcurrently`
  (= `PhysicalCores.count` = 18 here) frames in flight, so the machine is
  saturated and a stage's true price is the CPU it consumes, not how fast it
  finishes when it has all 36 threads to itself. This is exactly why my
  earlier note recorded `warpPerspective` at "1.375 s per source" while an
  isolated run of it measures 117 ms — same work, different contention.
- GPU numbers are Metal/MPS from Swift, min-of-5, kernels compiled at runtime.
- **Caveat:** an unrelated `Star.app` GUI run was occupying up to 16 cores for
  part of this session. It inflates wall-clock figures (the 41.8 s CPU pyramid
  vs 33.1 s measured on an idle machine) and it does not affect the ratios,
  which are large enough to survive it comfortably.
- The 12-frame reference CLI run started for this analysis was still in its
  keypoint/merge phase after 17 minutes. That is itself the finding.

Reproduction harnesses are in the session scratchpad: `bench2.cpp` (per-op
core-seconds), `pyr.cpp` (SIFT-shaped pyramid, CPU vs OpenCL), `metalbench.swift`
(MPS pyramid + transfer bandwidth), `kernels.metal` + `mergebench.swift`
(warp and sigma-clip median), `akaze2.cpp` (AKAZE threshold sweep).

---

## 3. Where the time actually goes

Per frame at 42 MP, static sequence, earth alignment on, 8 aligned neighbours:

| stage | core-s / frame | threads | GPU fit |
|---|---:|---|---|
| **AKAZE detect + compute** (earth keypoints) | **~48** (now ~33, §Tier 0) | 2.3 | good — nonlinear diffusion is a stencil |
| **SIFT detectAndCompute** (sky keypoints) | **~29** | **1.0** | excellent — it is a Gaussian pyramid |
| **8 warps + 8 coverage probes** (star-aligned merge) | **~25–30** | 26 | excellent — bilinear resample |
| **sigma-clipped median**, 9 sources | **~9** | 26 | excellent — per-pixel, fixed n |
| TIFF decode x9 (warm) | ~3–5 | 1.0 | none — stays on CPU |
| horizon detection (Canny/Sobel/DP/RandomWalker) | ~3–5 | 1.0 | partial (Canny 4x, Sobel 13x measured) |
| matching + RANSAC, 16 pairs | ~3–5 | 1.0 | modest |
| blob finding + classification (Swift) | see §7 | 1.0 | **poor** — order-dependent |

**Keypoints alone are ~77 core-seconds of roughly 130–160 per frame — 50-60%
of the auto path** (the AKAZE row read ~67 in the first draft; that came from a
harness that did not replicate the shipped preprocessing — see §Tier 0). Warp + merge is another ~35–40. Together the three GPU-
friendly stages are **~85% of the CPU cost of a run.**

Supporting per-op measurements at 42 MP (all single-threaded unless noted):

```
warpPerspective 16UC3 (36 thr)   wall   116.7 ms   core   3076.4 ms  (26.4 thr)
warpPerspective 16UC3 (1 thr)    wall  2457.7 ms   core   2413.7 ms
SIFT detectAndCompute (2000 kp)  wall 33142.8 ms   core  28604.4 ms  (0.9 thr)
SIFT detectAndCompute @half-res  wall  5058.3 ms   core   4271.7 ms
BFMatcher knnMatch 2000x2000x128 wall   218.4 ms   core    216.4 ms
distanceTransform L2             wall   451.2 ms   core    441.4 ms
CLAHE 4.0 8x8                    wall   407.6 ms   core    399.3 ms
Canny 50/150                     wall   401.2 ms   core    360.7 ms
dilate ellipse 21x21             wall   423.6 ms   core    418.3 ms
imread TIFF (warm cache)         wall   515.0 ms   core    511.1 ms
```

### Why SIFT is so expensive

`cv::SIFT` upsamples 2x before building the pyramid (`firstOctave = -1`), so at
42 MP the base of the scale space is **15904x10608 CV_32F = 644 MB**, and the
pyramid is 12 octaves x 6 layers = 55 blurs over 1,125 MP. That is also the
~7 GB/op that sets the whole run's memory peak, which in turn throttles frame
concurrency — so the stage is simultaneously CPU-bound, memory-bound, and
concurrency-limited. Moving the pyramid to the GPU relieves all three at once:
it runs in VRAM, which is a separate 16 GB pool.

---

## 4. GPU measurements

### Transfers (discrete GPU, PCIe 3.0 x16 — the worst case)

```
upload  241 MB shared->private blit:    21.9 ms  ( 11.5 GB/s)
upload  644 MB shared->private blit:    58.8 ms  ( 11.5 GB/s)
        makeBuffer(bytesNoCopy) wrap:    0.3 ms  (zero-copy)
```

A whole 42 MP frame crosses the bus in 22 ms against stages costing seconds.
On Apple Silicon (`hasUnifiedMemory == true`) even that disappears.

### Compute

```
MPSImageGaussianBlur sigma 1.6 on 168 MP:  17.45 ms  (77 GB/s effective)
FULL SIFT-shaped pyramid (55 blurs):      183.2 ms     [CPU: 41,831 ms]
warpPerspective 16UC3 42MP:                 0.99 ms     [CPU: 3,076 core-ms]
sigma-clip median,  9 sources, 42MP:      100.1 ms     [CPU: 9,100 core-ms]
sigma-clip median, 17 sources, 42MP:      566.5 ms
```

The warp at 0.99 ms is 482 MB of traffic in 0.99 ms = **487 GB/s**, i.e. it is
running at the Vega's HBM2 bandwidth limit. There is no headroom left to find
there; it is simply done.

### OpenCL, for the record

```
CPU  pyramid: wall  41831.3 ms   core  29671.8 ms
GPU  pyramid: wall  55902.5 ms   (via cv::UMat)
     upload of 644 MB base: 15621.4 ms   <-- 41 MB/s
```

Also note `opencv/build.sh` passes `-DWITH_OPENCL=OFF -DWITH_CUDA=OFF` for the
Linux/Windows builds, so the T-API is not even present off macOS.

---

## 5. Proposal

### Tier 0 — take the free CPU wins first (days, no GPU)

These came out of the profiling and should land before any GPU work, both
because they are cheap and because they change the baseline any GPU work is
measured against.

- **Raise the AKAZE threshold. DONE 2026-09-19** — `ia_find_features` set `1e-5`,
  which is AKAZE's `min_dthreshold` floor rather than a choice; OpenCV's own default
  is `1e-3`. Now `1e-4`. Measured with a harness that `#include`s the real
  `ImageAligner.cpp`, so the CLAHE / percentile-stretch / gradient-mask preprocessing
  is the shipped code, against real horizon masks (detect core-ms, and raw candidates
  before `retainBest` culls to 2000):

  | sequence | detect 1e-5 | detect 1e-4 | stage total 1e-5 | 1e-4 | candidates at 1e-4 |
  |---|---:|---:|---:|---:|---:|
  | a7iv-1 7008x4672 f901 | 27,538 | 15,746 | 38,681 | 26,376 | 80,714 (40x cap) |
  | a7iv-1 7008x4672 f950 | 24,191 | 14,394 | 35,355 | 25,270 | 90,005 (45x cap) |
  | a7sii-1 4240x2832 | 8,426 | 4,307 | 12,591 | 8,483 | 15,860 (7.9x cap) |
  | a7riii 7952x5304 | 32,901 | 18,014 | 47,999 | 32,498 | 40,669 (20x cap) |

  **~1.8x off detect, ~1.45x off the whole earth keypoint stage** — roughly 10-15
  core-seconds per frame. On all four, the retained 2,000 are *the same detections*:
  identical position, size, angle, response, octave and descriptor, verified byte for
  byte.

  **This corrects the 3.6x I first quoted.** That came from a throwaway harness that
  did not replicate the shipped preprocessing (it fed AKAZE a plain CLAHE'd frame, and
  found 915,611 candidates where the real path finds 163,485), and it quoted the `1e-3`
  row, which is a threshold that does not survive §Tier-0-risk below. The faithful
  harness is `akaze_sweep.cpp`.

  **Why not higher.** The saving plateaus immediately — 5e-5, 1e-4 and 2e-4 all land
  within noise of each other, because what remains is the nonlinear diffusion pyramid,
  which costs the same whatever the threshold. Above that the feature set starts to
  change: at 5e-4 the a7sii frame finds 2,230 candidates against a cap of 2,000 and one
  retained keypoint differs; at 1e-3 it finds 1,244 and misses the cap entirely.
  Empirically exact set identity needs ~10x the cap in candidates, and 1e-4 delivers
  8-45x. There is nothing to buy above it and a real margin to lose.

  A gap in this evidence: none of the sequences still on this volume has the crushed
  black ground that motivated `1e-5` (all measured 0.00-0.51% pure-black ground). The
  argument that it is safe there is reasoning, not measurement — a ground that thin
  already fails `groundConsensusIsUsable` and drops out of the earth merge.

  **What it does change: keypoint order, and the earth homography with it.** The
  retained set is identical but `retainBest`'s `nth_element` returns it in a different
  order, and `findHomography`'s RANSAC samples by index. Measured on real frame pairs,
  the resulting ground homographies move the frame corners by 18-169 px.

  That is *not* a cost of this change. The control — the **identical** feature set fed
  in reversed order at the **unchanged** 1e-5 threshold — moves them by 44-176 px, i.e.
  as much or more, and on one sequence flipped two neighbours from `HomographySuccess`
  to `NoHomographyFound`. The earth homography is already that order-sensitive on both
  sequences tested. Harness: `homog_cmp.cpp`.

  **This is worth its own investigation** (see §9). It means the ground warp is
  currently arbitrary among many mutually-inconsistent RANSAC consensus sets, while
  `groundConsensusIsUsable` reports them all as passing. Sorting the retained keypoints
  deterministically after `retainBest` would pin one answer and remove the
  `nth_element` instability, but it would not make the underlying fit well-conditioned,
  and it is an output change in its own right — so it is proposed, not slipped in here.

- **Keypoint divisor default. DONE 2026-09-19** — not to 2, as this first said. The
  codebase already carried a measurement I had not read: `recommendedReducedKeypointDivisor`
  is 1.5 because "on 42MP frames the two outputs were compared side by side and 1.5 was
  indistinguishable from 1.0 while 2 was visibly softer". Defaulting to 2 would have
  shipped visibly softer output.

  The other thing this first draft had wrong: the *policy* already existed. `Config.keypointDivisorAdvice`
  computes whether memory or core count binds keypoint concurrency for this sequence on
  this machine, is tested, and the macOS startup prompt already applied 1.5 from it. What
  was missing is that it lived in one client's view — **the cli and the daemon had none of
  it**, so a cli user at 42MP silently ran memory-throttled with no warning.

  So the change is to move the policy into `Config.resolveAutomaticKeypointDivisor`, called
  from `set(imageInfo:)`, which every client goes through. A new
  `Config.keypointDivisorWasChosen` separates "1.0 because that is the inline default" from
  "1.0 because somebody asked for it", and is set by the cli flag, the daemon's protobuf,
  the macOS settings and any config.json that already carries a divisor — so an explicit
  choice is never overridden, and a resume keeps the divisor its cached feature files were
  computed at.

  Measured on the 42MP sequence, the real effect is bigger than the per-op saving, because
  the divisor buys concurrency as well as speed:

  ```
  --keypoint-divisor 1   10 concurrent keypoint ops, 10136MB/op → bound by memory budget
  (new default, 1.5)     18 concurrent keypoint ops,  5068MB/op → bound by core count
  ```

  **1.8x more keypoint ops in flight, each ~2x cheaper** — call it ~3.5x on the sky
  keypoint phase's wall clock, and the memory peak that was throttling the whole run stops
  being the binding constraint.

  What it costs, measured through the shipped `ia_find_features` / `ia_compute_homography`
  on a 32.7MP sequence with real horizon masks — sky homography displacement at the frame
  corners against divisor 1.0:

  | | worst corner |
  |---|---|
  | divisor 1.5 | 0.15, 0.19, 0.64 px |
  | divisor 2.0 | 0.25, 0.30, 0.31 px |
  | **order-only control** (identical features, reversed, divisor 1.0) | **0.00, 0.59, 0.00 px** |

  At 1.5 the homography moves about as much as feeding RANSAC the identical feature set in
  a different order does. Note also what that control says in passing: **the sky homography
  is enormously better conditioned than the earth one**, which moved 44-176 px under the
  same treatment (§9).

  The corner metric is not the whole story — softness comes from sub-pixel misregistration
  accumulated across 8 neighbours and a whole sequence, which three corner displacements do
  not capture, and it is why 2.0 does not look worse here despite the recorded visual
  observation that it is. The side-by-side remains the better evidence for output quality;
  1.5 is what both agree on.

### Tier 1 — warp + merge on Metal (highest confidence)

`warpInto`, `warpCoverage` and `medianMergeTyped` are self-contained, live
behind `ia_align_and_median_merge`, and together are ~35-40 core-s/frame.
Keeping all 9 sources resident on the GPU for the merge means one upload
(~190 ms) and one download (22 ms) per merge instead of per op.

**This tier can be bit-identical.** OpenCV's `remapBilinear` is fixed-point
integer arithmetic (5-bit fractional coefficients), not float — reimplementing
that exactly in a Metal kernel reproduces it byte for byte, and the
`#include`-the-real-`.cpp` differential harness from
[[merge-step-cost-breakdown]] is the right instrument to prove it.

The merge kernel needs one decision: the CPU uses `double` Welford, and **Apple
Silicon GPUs have no fp64 at all**. The right answer is not to emulate it but to
replace it with an exact integer formulation — with n ≤ 17 and values ≤ 65535,
the sum fits in `uint32` and the sum of squares in `uint64`, both exact. Note
this *will* change output slightly: my 2026-08-23 note records that swapping
Welford for exact int64 changed 4 samples in 126.5 M and 1 of 20 frames. That
was rejected then because it bought no measurable speed; at 91x it is a
different trade, but it is a real output change and should be signed off, not
slipped in.

### Tier 2 — the scale-space pyramids (highest absolute win)

~96 core-s/frame → a few hundred ms. Two pieces:

- **SIFT's Gaussian pyramid** (sky). Build the pyramid and the DoG on the GPU,
  read back the extrema, and keep OpenCV's orientation/descriptor code on the
  CPU — those are O(keypoints), not O(pixels), and are not the cost. `MPSImage
  GaussianBlur` already does the blur at 17 ms per 168 MP level.
- **AKAZE's nonlinear diffusion pyramid** (earth). Same shape, more work: the
  FED solver is an explicit stencil, which is straightforwardly a compute
  kernel, but there is no MPS primitive for it — it has to be written.

**This tier cannot be bit-identical**, and that is the main risk. Keypoint
positions will shift in the last decimal, which moves homographies, which moves
every pixel downstream. It must be validated on behaviour rather than bytes:
the `homography.db` replay harness, `HomographyReciprocity`, and the recompute
harness from [[star-homography-recompute-harness]] are all already built for
exactly this question.

Do Tier 1 first regardless — it establishes the Metal plumbing, the buffer
lifetime discipline and the fallback path under a workload where correctness is
checkable byte for byte.

---

## 6. Architecture and cross-platform

Put a narrow interface in `StarCpp` — perhaps six entry points (`warp`,
`coverage`, `sigmaClipMedian`, `gaussianPyramid`, `dogExtrema`, `subtractClip`)
— with a **CPU implementation that always exists** and a GPU backend selected at
runtime. `Config` gets a tri-state `useGPU` alongside the existing knobs, and
the CPU path stays the reference the GPU path is diffed against forever, not
just during the port.

Backends, in the order they earn their keep:

- **Metal (macOS)** — primary. Covers the GUI, Intel+AMD Macs and Apple
  Silicon. On Apple Silicon unified memory removes the transfer term entirely
  and the GPU is relatively stronger than the CPU than it is here.
- **CUDA (Linux/Windows + NVIDIA)** — optional, later. OpenCV's `cudawarping`/
  `cudafilters` would cover much of Tier 1 without hand-written kernels, but it
  means rebuilding OpenCV with `WITH_CUDA=ON` per platform.
- **Vulkan compute** — the one-kernel-set-everywhere option, via MoltenVK on
  macOS. Tempting for reach, worse for macOS performance and a heavy new
  dependency. Only worth it if Windows/Linux GPU support becomes a real
  requirement.

Do not build on OpenCV's OpenCL T-API on macOS (§4), and do not expect it off
macOS either, since it is compiled out.

### Practical notes

- **`MTLDevice.maxBufferLength` is 3584 MB on this Vega.** The 17-source static
  earth merge is 4.1 GB and must be chunked. The 9-source star merge (2.17 GB)
  fits.
- **Max texture dimension is 16384.** SIFT's 2x-upsampled base at 42 MP is
  15904x10608 — it *just* fits. A 61 MP body (9504x6336 → 19008x12672) does
  not. Either tile, or use buffers rather than textures, or skip the doubling.
- **The offline Metal toolchain is not installed on this machine**
  (`xcrun metal` fails, wants `xcodebuild -downloadComponent MetalToolchain`).
  Shipping wants a precompiled `.metallib`, so this becomes a build
  prerequisite alongside the OpenCV and decision-tree artifacts.
- GPU memory has to join the existing accounting. `MemoryMonitor`'s ledger
  ([[memory-gate-ledger-realization]]) governs system RAM; VRAM is a second,
  smaller, separate pool and a merge that fits in 128 GB may not fit in 16 GB.
- The GPU is a single shared resource across 18 concurrent frames. Work must be
  serialised through one queue with bounded in-flight buffers, or it will simply
  move the memory-pressure problem from RAM to VRAM.

---

## 7. What is *not* worth putting on the GPU

- **`FullFrameBlobber`.** It sorts every above-threshold pixel by brightness and
  flood-fills from the brightest down, so the result depends on visit order —
  a parallel connected-components pass is a *different algorithm* with different
  output, and the decision trees are trained on the current one. It has a real
  performance problem (it `await`s an actor, `PixelStatusTracker`, once per
  pixel inside a serial loop), but the fix is Swift data-structure work, not a
  GPU.
- **The DP horizon.** The column scan is inherently sequential.
- **TIFF decode.** Measured 515 ms/frame warm, 1.07 s cold off the external SSD;
  device-bound, not compute-bound.
- **Matching and RANSAC.** ~0.2 core-s per pair at 2000x2000x128. Real, but a
  rounding error next to 96 core-s of detection.
- **`dilate` / `GaussianBlur` at small kernel sizes.** Measured *slower* on the
  GPU (0.88x, 0.36x) — launch overhead dominates. Only fuse them into a chain
  that is already resident on the GPU; never round-trip for one of them.

---

## 8. Suggested order

0. **The earth homography was degenerate by construction. FIXED 2026-09-19.** Turned up by
   the Tier 0 work, and worth more than any of the GPU work below. Ground inliers sit in a
   band 87-98% of the frame wide and only **11-42% of its height**, which leaves an 8-DOF
   homography under-determined: it satisfied every inlier it sampled — ratio 0.87-0.88,
   well over `groundConsensusIsUsable`'s 0.65 — and was then free to do anything above and
   below them. An inlier *ratio* cannot detect this by construction: it measures whether
   the correspondences agree with the model, not whether they constrain it.

   The ground now fits a 4-DOF similarity (`estimateAffinePartial2D`, lifted to 3x3) in
   `estimateAlignment`. **The sky is unchanged** — it is well conditioned (0.00-0.59 px
   under the same test) and must stay a full homography.

   Validated by `homography.db` replay over a 12-frame `--moving-camera` run, 76 stored
   earth homographies:

   - **72 of 76 replay to <0.01 px** of what the run stored. The 4 that do not are exactly
     the 4 the db marks `UsedExistingHomography` — written by the smoothing stage, not the
     aligner. 72 of 72 on everything the aligner produced.
   - **Mean |corner displacement - phase-correlation truth|: 2.66 px, against 40.09 px for
     the old homography**, with mean true ground motion 7.58 px. The old fit was off by 5x
     the signal; the new one by about a third of it.

   Full StarCore suite green, including the alignment, earth-chain, ground-tracking and
   reciprocity suites; cli, daemon and gui all build.
1. Tier 0 — AKAZE threshold (done), keypoint-divisor default. Days. No new
   machinery. Re-measure the baseline afterwards.
2. Tier 1 — Metal backend skeleton + `warp` / `coverage` / `sigmaClipMedian`,
   proved bit-identical with the existing differential harness.
3. Measure a full run. Decide whether Tier 2 is still worth it against the new
   baseline — Tier 0 may have taken a third of the keypoint cost already.
4. Tier 2 — SIFT pyramid, then AKAZE diffusion, validated against
   `homography.db` rather than against bytes.
5. Only then consider a second backend, driven by where users actually are.

Expected outcome if all of it lands: the auto path's CPU cost falls by roughly
**5-8x**, and the run stops being gated by the keypoint phase's memory peak,
which should let frame concurrency rise as well.
