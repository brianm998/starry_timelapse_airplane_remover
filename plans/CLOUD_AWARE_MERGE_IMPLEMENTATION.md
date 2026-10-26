# Cloud-aware merge — implementation guide

Status: designed and prototyped in numpy on 2026-10-20/21; **not implemented**. This file
is the complete brief for implementing it in StarCpp. It is self-contained: the reasoning
is in §1, the algorithm in §2, where it goes in §3, how to check it in §6–7, and the
runnable reference prototype that defines the expected output is in Appendix A.

---

## 0. Summary for the implementer

- **Problem.** In automatic mode, fast-moving clouds (worst at dawn/dusk) come out banded
  and "repeated": copies of the cloud's edges from different frames, frozen in place
  while the real cloud moves. Slow clouds come out thinned and smeared.
- **Fix.** Add an optional second stage to the star-aligned merge
  (`ia_align_and_median_merge` in `StarCpp/Sources/StarCpp/ImageAligner.cpp`):
  1. estimate how the clouds move relative to the stars;
  2. merge the neighbours a second time, aligned to the clouds;
  3. use that merge wherever it explains the frame better than the star merge, with the
     stars put back from the star merge.
  Clear sky is untouched: in the sky interior of a clear frame the output must be
  **byte-identical** to today's.
- **Scope.** One Bool config flag, `cloudAwareMerge`, **default `false`**, applied to
  star-aligned merges only. Plumbed through the Swift bridge, `FrameAlignmentProcessor`,
  `Config`, `ArtifactInputs` and a CLI flag. No GUI, daemon or desktop-client surfaces in
  v1 (§3.5).
- **Done** means every acceptance check in §7 passes on the user's real sequence and the
  unit tests in §8 exist and pass. Leave the default at `false`: turning it on is the
  user's decision after watching the comparison clip.

Work in a new worktree branched from `develop`.

---

## 0.1 Implementer's notes (2026-10-21, from building it against the real data)

Where the implementation departs from this guide, and where the guide turned out to be
wrong. The sections below are left as written; read this first.

**Wrong or incomplete in the guide**

- **The reference run's star merge came from the GPU kernel.** `config.json` of
  `star_temp_LRT_10_17_2026-fx3-1` says `useGPUForMerge: false`, but replaying frame 30
  with `useGPU: true` is *byte-identical* to `auto-processed/LRT_00030.tif` in the crop
  (`magick compare -metric AE` = 0), and `useGPU: false` differs on 2.6% of its pixels
  (a spread of ±1..3 on single channels, the signature of the GPU kernel's exact-integer
  statistics against the CPU's double Welford). So the baseline "today" for fx3-1 is the
  GPU merge, §6.3's `useGPU: false` is wrong, and the stage has to work after the GPU merge
  (it does; there it derives its own coverage plane).
- **eM is not near zero on a clear frame, so §2.2's gate cannot skip one.** Measured over
  the whole frame, the star merge's error sits at about 0.23 of the per-pixel noise with a
  floor of 0.3, and exceeds the floor on 1.5%, 8%, 16% and 4% of the sky of frames 1100,
  700, 600 and 800 (the "0.3% on clear crops" the guide quotes is the crops, rows 800-1800,
  away from the edges and the horizon). Restricting to the region where `eM > floor` then
  covers most of the frame. See the early-out below.
- **Frames 600 and 800 are not clear.** Both have real cloud near the horizon (a dark bank at
  the right of 600, a small cloud at 800), and the stage's weight is above zero exactly
  there (rows 1886-2188). §7 A2's "byte-identical for rows < 2189" holds on 700 and 1100,
  and in the reference crop on all four, but cannot hold on frames with cloud in those rows.
- **The star merge is contaminated along the horizon, which §2.8 does not account for.**
  Neighbour ground is lifted above the base horizon by up to 33-47px and the error filters
  reach 92px beyond that. Production already knows this and replaces those pixels with the
  earth image (`StarAlignedHorizonMask`). Without excluding them the stage runs on every
  frame, clear or not, to repair a band the composite throws away.

**Additions to the algorithm (all in `ImageAligner.cpp`, "Cloud-aware merge")**

- *Trusted sky.* The weight is only allowed above zero where the star merge can be trusted:
  the sky mask intersected with itself warped by each neighbour's homography (production's
  recipe, NEAREST, border white), then eroded by 96px so that eM's own reach never touches
  the smeared ground. Done at 1/4 resolution (a 193x193 erosion at full size cost more than
  the rest of the setup). Clouds within ~100px of the horizon are left as today.
- *No-cloud early-out.* After the grid median, if fewer than 6 tiles of trusted sky have a
  cloud velocity of at least 3 low-res px/frame (12 full-res px/frame) the stage returns the
  star merge. On four clear frames that count was 2-15 of 211 trusted tiles, on cloud frames
  204-210. A sparse one-neighbour pre-filter runs first so a clear frame pays for a fraction
  of one velocity search. The correlation peaks themselves do *not* separate the cases (a
  clear frame's best non-zero shift is the wing of the excluded star peak, peak 0.5-0.99).
- *Region from an upper bound.* The weight is `clamp((rel-0.2)/0.3) * g` with
  `g = clamp((eM-floor)/floor)`. Blurring `g` alone bounds the weight from above everywhere,
  and the weight snaps to 0 under 0.01, so wherever the bound is under 0.01 the output is
  provably the star merge. The full-resolution work runs on the bounding box of the bound's
  support plus 160px (the weight's whole dependency cone is 140px), and the bound is also
  what the snap is applied through, so the region changes nothing (§8 test 8).
- *Exact blurs.* Every full-resolution blur is an integer box filter on values quantised to
  1/256 (1/65536 for weights), not `cv::blur`. A float running sum depends on where the
  window starts in its last bits, so a crop and the whole frame would disagree and "the
  region changes nothing, byte for byte" would be false to within a rounding that flips whole
  output values. Integer sums are exact in any order.
- *Motion is measured on the whole frame*, not on the region: the nearest-measured fill rule
  makes a tile's value depend on which other tiles were measured.
- *Parabola refinement only around a true local maximum.* The unmasked neighbours can include
  the excluded zero-shift peak, which otherwise extrapolates by several pixels.
- *Star coverage is derived lazily* on the GPU path (eight full-frame warps), only for a
  frame that gets as far as the weight.
- A prediction that puts the search window off the frame leaves the tile unmeasured and it is
  filled from the nearest measured tile (§2.3), not "fall back to the prediction" (§4).

**Tuning the cloud share (noise floor ×6 → ×8).** Through the C++ the stage counted more of a frame as cloud
than the numpy prototype did: the share of the A3 crop with weight above 0.5 was +0.099 on #45, +0.119
on #60 and +0.184 on #72 against the prototype's, all faint-cloud frames where today's output already matches the
exposed frame well. Eight settings over twelve frames (28, 30, 45, 60, 6, 7, 53, 72, 91, 20, 36, 85), same
replay, scored against the references:

| floor multiple (of 0.05σ) | relative ramp | #45 | #60 | #72 | #85 | mean \|share diff\| | CLOUDCORR mean / min |
|---|---|---|---|---|---|---|---|
| 6 (the guide) | 0.2-0.5 | +0.099 | +0.119 | +0.184 | +0.057 | 0.064 | 0.960 / 0.934 |
| 7 | 0.2-0.5 | +0.088 | +0.080 | +0.121 | +0.011 | 0.047 | 0.960 / 0.934 |
| **8 (implemented)** | 0.2-0.5 | **+0.076** | **+0.037** | **+0.057** | **-0.039** | **0.036** | **0.959 / 0.933** |
| 9 | 0.2-0.5 | +0.059 | -0.016 | -0.001 | -0.090 | 0.033 | 0.959 / 0.930 |
| 10 | 0.2-0.5 | +0.044 | -0.071 | -0.056 | -0.136 | 0.047 | 0.958 / 0.926 |
| 6 | 0.3-0.6 | +0.049 | +0.090 | +0.141 | +0.020 | 0.049 | 0.952 / 0.914 |
| 8 | 0.3-0.6 | +0.030 | +0.017 | +0.028 | -0.063 | 0.039 | 0.951 / 0.914 |
| 7 | 0.25-0.55 | +0.067 | +0.069 | +0.106 | -0.002 | 0.041 | 0.956 / 0.932 |

The floor is the lever; the relative ramp costs fidelity (frame 7 falls to 0.914) for a smaller change. 7 leaves
#72 outside tolerance, 9 puts #85 at -0.090 and 10 at -0.136, so 8. Over all 90 frames at 8: share difference mean
+0.005 (it was biased high), range -0.069 to +0.133, three frames outside ±0.10 (#47 +0.133, #59 +0.127, #54 +0.112; none
is one A4 names), per-frame CLOUDCORR change at most -0.003 (frame 60) against ×6, and no frame lost more than 0.005.
A clear frame is not affected: its floor only matters after the early-out, which has already returned.

**Results (fx3-1, the final code; "CLI" = end to end through `star`, "replay" = the harness)**

| # | Result |
|---|---|
| A1 | Flag off changes nothing: all 19 frames of `test_data/test_a7sii_10` are byte-identical (AE 0) to a CLI built from plain `develop`. StarCpp 209 tests, StarCore 1369 (0 failures), cli 66, daemon and gui build. The three failures that remain also fail on plain `develop`: `OpenCVQoSTests.testLowQoSUsesFewerWorkersThanNormalQoS` (the vendored OpenCV lacks the QoS patch), `ConfigOverridesTests.testEveryOverrideIsWiredToAFlag` (`--use`'s `resourceProfile` is not in its flag list) and `GherkinTests.testOpenAndProcessFeature` (temp dir cleanup). |
| A2 | Frames 600, 700, 800, 1100 with the flag on are byte-identical to flag off over the **whole frame** (AE 0), because the stage stops at its pre-filter on all four. (Before the early-out existed, 600 and 800 had weight up to 0.24 in rows 1886-2188, where they have real cloud.) |
| A3 | Frames 6-95 on the A3 crop (replay, final code with the floor at ×8): CLOUDCORR **min 0.933, mean 0.965** (reference 0.949, today 0.599). Worst: #72 0.933, #53 0.934, #7 0.948. At ×6 it was min 0.934, mean 0.965; the CLI end-to-end output of the final binary gives min 0.932, mean 0.964. |
| A4 | Cloud share (weight > 0.5), floor at ×8: #28 0.744 (reference 0.764, -0.020), #30 0.847 (0.783, +0.064), #45 0.418 (0.342, +0.076), #60 0.537 (0.500, +0.037): all inside ±0.10. At ×6 #45 was +0.099 and #60 +0.119 (outside). Over all 90 frames three that A4 does not name are still outside: #47 +0.133, #59 +0.127, #54 +0.112. |
| A5 | #28 trail: **+0.26σ** (original +2.69σ, today +0.18σ, reference +0.24σ). |
| A6 | Stars kept in cloud, CLI: #30 median 0.99, 96% kept at >= 80%; #60 median 0.96, 96% kept. Replay: 1.01 / 0.98 and 1.00 / 0.98 (the reference's numbers). |
| A7 | Triptych of frames 6-95 rendered (`triptych.mp4`, 90 frames). Stills at frames 12, 30 and 60 show today's stepped, repeated cloud edges gone and the exposed frame's structure kept, stars intact inside the cloud, the thin streak at frame 60 removed. Flicker, measured as the frame-to-frame jump of the brightness offset from the original: std 0.97 against today's 1.33, max 3.6 against 6.2. Not watched as motion. |
| A8 | Whole-run CPU, `star -c automatic`, default GPU, 18 concurrent frames, user+sys: frames 600-700 flag off 5008 / 6055 / 5999 CPU-s, flag on 6110 / 5983 on the final binary (+0.9%, -0.3%; a first on-run with an earlier binary read +11.6%, which is inside this machine's ±10% run-to-run noise). The stage itself measures 0.57 CPU-s per clear frame in the replay (stops at the pre-filter on all 101 frames of 600-700). Frames 1-100 (cloud), three flag-off/on pairs: 4615 -> 6987 (+51%, earlier code), 5650 -> 8885 (+57%) and 5072 -> 8064 CPU-s (+59%) with the final binary, i.e. +24 to +32 CPU-s a frame (the replay measures the stage itself at 25-35), wall +16%, +30% and +22%. Peak op memory, 12 frames of fx3-1 at concurrency 1 with `--log-op-memory`: unchanged to within 11MB (+892MB both). |
| A9 | `StarCpp`, `StarCore`, `cli`, `daemon` build and test as above; gui `xcodebuild -scheme star` succeeds. |
| §6.5 | Horizon, frames 6-20, final composite flag on against off: no pixel differs closer than 67px above the horizon, the weight is zero on every ground pixel, and an amplified difference image shows no seam or ghost ridge along the horizon. |

**Tools**

- `StarCpp/Tests/StarCppBridgeTests/CloudAwareMergeReplayTests.swift` is the replay harness
  of §6.3, skipped unless `STAR_CLOUD_REPLAY=1`; its doc comment lists the environment
  variables and modes (`off`, `on`, `off-gpu`, `on-gpu`, `on-full`, `on-stream`). Build it
  in release (`swift test -c release -Xswiftc -enable-testing`): debug runs the C++
  unoptimised and a 12MP frame takes minutes. It keeps decoded frames for the run, as a
  pipeline keeps the decodes it pins, so timings are not the cost of decoding twice.
- With `cloudDebugDir` the stage writes `cloud-alpha-<n>.tif`, `cloud-velocity-<n>.txt`,
  `cloud-error-<n>.tif` (eM, 16-bit) and `cloud-stats-<n>.txt` (outcome, noise, floor, region,
  evidence counts, wall and CPU time per phase).

---

## 1. Background

### 1.1 What automatic mode does

For each frame, `FrameAlignmentProcessor` (`StarCore/Sources/StarCore/FrameAlignmentProcessor.swift`,
the `ImageAligner.alignAndMedianMerge` call near line 1052) warps the ±4 neighbouring
frames (`numberAlignedNeighborFrames` = 8) onto the frame with their star homographies and
merges the 9 sources with `medianMergeTyped` (`ImageAligner.cpp` ~line 259). The kernel
works per pixel *and per channel*: it sorts the 9 values, discards values ≥ mean + k·σ
(k = `pixelThreshold`, 1.2), and outputs `sorted[(minIndex + maxIndex) / 2]`.

In automatic mode the frame you see in the sky *is* this merge
(`FrameAirplaneRemover.createAutoProcessedImage`). The same image is also the reference
for selective mode's subtraction image (`loadOrCreateSubtractionImage`,
`FrameAirplaneRemover.swift` ~line 1987) and the pixel source for blob replacement (loaded
~line 755, used ~1190–1443). A fix here therefore helps both modes.

### 1.2 Why clouds duplicate (measured)

Measured on `/sp/tmp/LRT_10_17_2026-fx3-1` (Sony FX3, 4240×2832, 16-bit, static tripod,
1304 frames, dusk to night, ISO-ramped and brightness-compensated with LRTimelapse):

- **Clouds move against the stars.** After star alignment, clouds here move 20–80px per
  frame (faster higher in the sky). The ±4-frame window therefore holds each cloud at 9
  positions, up to ~650px apart.
- **Each pixel takes a different moment.** A map of which source frame each output pixel
  of frame 30 came from shows vertical bands. Every offset from −4 to +4 supplies 9–15% of
  pixels, so the output is a patchwork of the cloud at different times: its edges
  repeated ~one frame's motion apart.
- **Colour fringes.** 72% of pixels take R, G and B from different frames, which shows up
  as magenta and green speckle clumps in cloud.
- **The bands lag.** Consecutive outputs share 7 of their 9 sources, so the bands creep
  instead of moving with the cloud. That's what reads as "the cloud repeated in each
  frame".
- **It is the merge itself.** A numpy replay of frame 30's merge matched production to a
  mean |difference| of 1.6/65535. The bands are present in the star-aligned image before
  any horizon compositing.

### 1.3 Why the fix has two layers

Aligning the neighbours to the cloud motion instead of the stars makes the clouds line up,
so the median keeps the cloud as it looks in the base frame. Airplanes, satellites and
meteors are still single-frame outliers in that stack, so they're still rejected. But the
stars no longer line up, so this merge has none.

So the output takes the cloud from the cloud-aligned merge, the stars from the star
merge, and stays exactly the star merge wherever there's no moving cloud.

Approaches that were tried and rejected:
- **Keep the original pixel unless it's a ≥5σ thin outlier against both merges.** This
  preserves cloud texture exactly, but it caught only fragments of a faint satellite. It
  would need the existing trail-finding machinery to be complete.
- **Fewer neighbours.** This narrows the band spacing but weakens trail rejection, and
  doesn't remove the bands.
- **Real dense optical flow (DIS/Farneback).** Not available: the vendored OpenCV is
  built without the `video` module (`opencv/build.sh`,
  `BUILD_LIST=core,imgproc,imgcodecs,features2d,calib3d,flann,highgui`). A tile-level
  motion field was enough on this data (§9 covers when it might not be).

---

## 2. Algorithm (normative)

This is the specification. The numpy prototype in Appendix A is the executable form of
it. Where this text and the prototype disagree, the prototype is what produced the
reference numbers. Report any discrepancy rather than silently picking one.

### 2.1 Inputs and output

- `B`: the base frame, `CV_16UC3`, **BGR channel order** (as `cv::imread` gives it). 8-bit
  input must also work; the kernel already supports `uchar`.
- For each neighbour `j` (offsets in −4..−1, +1..+4; fewer at sequence ends, see §2.8),
  the original decoded frame `N_j` and its star homography `H_j` (neighbour → base,
  `warpPerspective` convention: the star-warped neighbour is `S_j(x) = N_j(H_j⁻¹ x)`).
- `M`: the existing star merge, i.e. what `ia_align_and_median_merge` produces today.
- `k`: `pixelThreshold` (the same value the star merge used).
- `sky` (nullable): the frame's final horizon mask, `CV_8UC1`, non-zero = sky. Null when
  horizon detection is off.
- Output `O`, the same type and size as `M`.

Notation:
- `Y(X)` is luma: `0.2126·R + 0.7152·G + 0.0722·B`. With BGR Mats that is
  `0.0722·ch0 + 0.7152·ch1 + 0.2126·ch2`. Compute in `CV_32F`, in raw 16-bit units.
- `box3(X, r)` is three successive box blurs of size `(2r+1)×(2r+1)` with
  `BORDER_REPLICATE` (≈ a Gaussian with σ ≈ r).
- `open7(X)` is a grey morphological opening with a 7×7 square, applied per channel;
  `tophat7(X) = X − open7(X)`.

### 2.2 Step A — gate (cheap; decides whether anything else runs)

1. `LB = Y(B)`, `LM = Y(M)`.
2. `lp(X) = box3(median5(X), 6)`, where `median5` is a 5×5 median that removes stars.
3. `eM = box3(|lp(LB) − lp(LM)|, 24)`: how badly the star merge explains the base, in
   star-free low frequencies.
4. Noise: `d = LB[:, 1:] − LB[:, :-1]` (horizontal differences, which ignores stars),
   then `σ_pix = 1.4826 · median(|d − median(d)|) / √2`. Take `d` only over pairs where
   both pixels are sky when a sky mask is given; otherwise over the whole frame. All the
   reference crops are pure sky, so sky-only is what reproduces them.
5. `floor = max(6 · 0.05 · σ_pix, 1.0)`, in the image's own units. The `1.0` guards
   noiseless input (synthetic tests, 8-bit frames with clipped black), where `σ_pix` can
   be 0.
6. **If `eM ≤ floor` at every sky pixel, return `M` unchanged** ("sky" is the whole frame
   when there is no mask). This is exact: the cloud weight in Step D has a factor that is
   0 wherever `eM ≤ floor`, and is forced to 0 on the ground. On the clear crops tested,
   eM exceeded the floor on only 0.3% of pixels, so this gate alone won't skip most clear
   frames. Restricting the later steps to the regions where `eM > floor` (§5 step 3) is
   what makes clear frames cheap.

### 2.3 Step B — cloud motion field, per neighbour

All of Step B runs at 1/4 resolution (`f = 4`).

1. **Low-res star-aligned layers.**
   - `b = Y(B)` downsampled by 4 with `INTER_AREA` (block mean; the prototype floors odd
     sizes).
   - For each neighbour, `s_j` = `Y(N_j)` downsampled the same way, then warped with the
     scaled homography `D·H_j·D⁻¹`, where `D = diag(1/4, 1/4, 1)`.
   - The prototype downsampled the full-res star-warped neighbour instead; this is
     equivalent for a field this coarse.
   - Keep a low-res coverage mask per neighbour (warp a 255 probe the same way).
   - Frame sizes not divisible by 4: downsample `floor(W/4) × floor(H/4)` from the
     top-left, as the prototype does. The last 1–3 rows/columns get the field by the
     clamped upsampling in step 7.
2. **Band-pass, star-free.** `bp(X) = box3(median3(X), 1) − box3(median3(X), 12)`, where
   `median3` is a 3×3 median. Stars are ~1px at this scale, so the median removes them;
   the large blur removes the sky gradient.
3. **Tiles.**
   - 96×96 low-res px, step 48, top-left corners at `y = 0, 48, …` while `y + 96 ≤ H/4`
     (same in x).
   - Tile centre in full-res px: `4·(y + 48)`.
4. **Tile search.** For one tile and neighbour `j`, find the shift `s = (dy, dx)` that
   maximises the normalised cross-correlation between the base window
   `bp(b)[y:y+96, x:x+96]` and the neighbour window displaced by `s`.
   - Search `s` within ±R of a predicted shift `p` (so the search covers p + (−R..R)).
   - **Exclude every absolute shift with `(p_y+dy)² + (p_x+dx)² < 4` low-res px².**
     After star alignment, stars sit at exactly zero shift, and on starry frames they win
     the correlation. Without this exclusion the field read zero over visibly moving
     cloud.
   - Excluding zero is safe: where there is no cloud, the forced non-zero answer is
     rejected by Step D.
   - Refine the peak to subpixel with a 3-point parabola per axis, using the *unmasked*
     correlation values. Skip an axis's refinement when the peak sits on the edge of the
     search window or a neighbour on that axis is outside it. The tile's result is
     `d = p + s`, with `s` the refined shift.
   - Implementation hint: `cv::matchTemplate(searchRegion, baseTile, TM_CCOEFF_NORMED)`,
     then mask the excluded entries to −∞ before `minMaxLoc`. The prototype used a
     Hann-windowed circular FFT correlation instead. Either is acceptable if the §7
     numbers pass.
   - **Clip the search region** to the frame and to the neighbour's low-res coverage, and
     search only the shifts whose displaced window fits inside it.
     - Edge tiles therefore get a smaller search, not no search.
     - With `matchTemplate` and R = 46 the full region is 188px; dropping every tile
       whose full region doesn't fit would lose the whole outer ring of tiles.
     - The prototype never dropped a tile: its crops had margin on every side.
   - A tile is **unmeasured** when no candidate shift is left after clipping and
     exclusion, when the base tile is outside coverage, or when the tile contains no sky
     pixel. Before the grid median, fill each unmeasured cell with the value of the
     nearest measured cell (Chebyshev distance on the grid, ties broken in row-major
     order), or with `p` (0 for the velocity stage) if no cell was measured.
5. **Velocity per tile**, from offsets ±2 with `p = 0` and `R = 46`. R must stay below
   96/2; 48 overruns the window.
   - Both sides present: `v = (d₊₂ − d₋₂) / 4`. Other cases are in §2.8; they use the
     same `R` and exclusion.
   - Using ±2 rather than ±1 doubles the displacement, so slow cloud clears the excluded
     zero-shift disc.
   - Then a componentwise 3×3 median over the tile grid, with replicated edges.
6. **Each neighbour** `j`: search with `p = round(j·v)` per tile and `R = 16`, with the
   same exclusion. Then the same 3×3 grid median, giving `d_j` per tile in low-res px.
7. **Upsample** `d_j` to a full-res field:
   - bilinear between tile centres, held constant beyond the outermost centres;
   - multiply by 4.
   - The prototype's `upsample_field` is the exact rule.

### 2.4 Step C — cloud-aligned stack and merge

1. **Cloud-aligned neighbour.** `C_j(p) = N_j(H_j⁻¹ (p + d_j(p)))`, i.e. the star-warped
   neighbour sampled at the cloud displacement.
   - Build `mapx`/`mapy` (`CV_32FC1`, perspective divide included) and use
     `cv::remap(N_j, C_j, mapx, mapy, INTER_LINEAR, BORDER_TRANSPARENT)` into a zeroed
     destination.
   - That is one interpolation from the original. The prototype did two (warp, then
     resample); one is better.
2. **Coverage.** Remap a 255 probe through the same maps. Count the uncovered sources per
   pixel into a `misses` plane, exactly as `ia_align_and_median_merge` does for the star
   warps (`CoverageMisses`). **Zero is not "no data"**: real black pixels exist, and that
   bug has been fixed twice in this file.
3. **Merge.** `Rc = medianImageFromMats({B, C_1, …}, k, includeAll=false, missesC)`, the
   unchanged kernel. B is its own cloud-aligned layer (zero displacement).

### 2.5 Step D — cloud weight α

1. `LC = Y(Rc)` and `eC = box3(|lp(LB) − lp(LC)|, 24)`, with `lp` as in Step A.
2. `rel = 1 − eC / max(eM, 1e-6)`: the share of the star merge's error that the cloud
   merge removes.
3. `α_raw = clamp((rel − 0.2) / 0.3, 0, 1) · clamp((eM − floor) / floor, 0, 1)`.
4. **Set `α_raw = 0` where the frame's horizon mask says ground** (§2.8), and wherever
   either stack has a missing source (`misses > 0` in the star or cloud coverage plane:
   the frame edges, where the warps don't reach).
   - The star coverage plane already exists on the CPU paths (`misses` in
     `ia_align_and_median_merge`); pass it in.
   - The GPU fused path returns before building one, so there the cloud stage computes
     it itself with `warpCoverage` per neighbour.
5. `α = box3(α_raw, 16)`.
   - The zeroing in step 4 happens **before** this blur and is not repeated after it. α
     can therefore be non-zero up to 48px (3 × 16) past the edge of a zeroed region: just
     below the horizon and just inside an uncovered edge strip.
   - That's deliberate. Re-zeroing after the blur would draw a hard α step at the
     coverage boundary, which is visible where cloud reaches a frame edge.
   - Below the horizon it's invisible, because the composite takes the ground from the
     earth layer.
6. **Snap:** treat `α < 0.01` as 0 and `α > 0.99` as 1.
   - Measured on full clear frame 700: in the sky interior α never exceeded 0.001 (on
     0.14% of pixels). Without the snap those pixels would differ from today by a few
     DN; with it the interior is byte-identical.
   - The blend that the snap removes is invisible.
   - The reference numbers in Appendix B were produced without the snap. At this
     threshold the difference is far below the §7 tolerances.

### 2.6 Step E — compose

1. `stars = min(tophat7(M), tophat7(B))`, per channel. A star is in both images. The star
   merge's own speckles are not in the base, and a trail in the base is not in the star
   merge, so the minimum keeps stars and drops both.
2. `cloudLayer = open7(Rc)`, per channel.
3. `O = (1 − α)·M + α·(cloudLayer + stars)`, computed in float and stored with
   `saturate_cast` after rounding.
4. **Wherever α == 0 (after the threshold), copy `M` bit for bit.** Don't blend there.

### 2.7 Parameters (all measured on fx3-1; keep them as named constants, not Config)

| Constant | Value | Notes |
|---|---|---|
| downsample for motion | 4 | |
| star median at 1/4 res | 3×3 | |
| band-pass radii | box3 r=1 minus box3 r=12 | at 1/4 res |
| tile / step | 96 / 48 | at 1/4 res (384 / 192 full-res) |
| velocity offsets | ±2 | fall back per §2.8 |
| velocity search R | 46 | must be < tile/2 |
| per-offset search R | 16 | around round(j·v) |
| zero-shift exclusion | dy²+dx² < 4 | low-res px, absolute shift |
| α median / low-pass | median 5×5, box3 r=6 | full res |
| α error blur | box3 r=24 | |
| rel ramp LO / HI | 0.2 / 0.5 | |
| noise floor | max(8 · 0.05 · σ_pix, 1.0) | **×8 as implemented, not ×6** (see 0.1, "Tuning the cloud share"). ×6 was the smallest multiplier that zeroed α on the clear frame (×3 left patches up to 0.44); σ_pix over sky pixels |
| α smoothing | box3 r=16 | |
| star top-hat / cloud opening | 7×7 square | |
| α zero/one snap | 0.01 / 0.99 | |
| α forced to 0 | ground (horizon mask) and pixels any source doesn't cover | |

### 2.8 Edge cases

- **Sequence ends.** `calculateNeighborIndices` truncates the window rather than shifting
  it: frame 0 gets offsets +1..+4 only. Velocity, in order of preference (always
  `R = 46`, `p = 0`, the same exclusion):
  1. ±2 both present: `(d₊₂ − d₋₂)/4`;
  2. one of ±2: `d₊₂/2` or `−d₋₂/2`;
  3. ±1 both present: `(d₊₁ − d₋₁)/2`;
  4. one of ±1: `d₊₁` or `−d₋₁`;
  5. none: skip the cloud stage (return `M`).
  Cases 3–4 can't see cloud slower than ~2 low-res px/frame (8 full-res px/frame)
  because of the exclusion; that slow cloud is only smoothed today anyway.
- **A neighbour with no homography, or a failed decode.** It's absent from both stacks,
  as today.
- **`includeAll == true`.** Skip the cloud stage; nothing in production passes true.
- **The ground (measured, so restrict to the sky in v1).** Below the horizon, the
  star-aligned neighbours' ground moves by the star motion. The motion search locks onto
  it and α turns on: on full-frame runs α > 0 covered 40% of the ground on clear frame
  700 and essentially all of it on frame 30.
  - The composite replaces the ground with the earth layer, so it isn't visible, but it
    costs time and makes byte-identity on clear frames impossible.
  - `FrameAlignmentProcessor` already loads `horizonMask` (the final horizon mask, white =
    sky) right before the merge call. Pass it in (§3.1–3.3), force `α_raw = 0` on the
    ground, and skip tiles that are entirely ground.
  - With horizon detection off there is no mask; then run on the whole frame.
  - Whether the horizon feather band changes visibly is still unverified (§6.5).
- **Frame edges.** Where a warp doesn't reach, a source is missing. Force `α_raw = 0`
  there (§2.5).
  - The prototype modelled edges crudely (zero padding, no coverage plane). On full clear
    frame 700 it left α up to 0.15 in the top 200px and along the side edges.
  - So edge behaviour is not validated by the prototype; it's covered by the coverage
    rule and §7 A2.
- **Not the earth merges.** The static earth merge (`PixelatedImage.medianMerge(with:)`)
  and the moving-camera earth-aligned merge (the same `alignAndMedianMerge` call with
  `type == .earthAligned`) must never run the cloud stage.

---

## 3. Where it goes

### 3.1 C++ (`StarCpp/Sources/StarCpp/ImageAligner.cpp`, `include/ImageAligner.h`)

- **Function shape.** Add a new section ("Cloud-aware merge") with one entry function
  taking:
  - the base and `M` (`const cv::Mat &`);
  - the same neighbour and homography arguments `ia_align_and_median_merge` receives
    (`baseFrameIndex`, `neighbors`/`neighborCount`, `homographyKeys`/`homographyValues`/`homographyCount`);
  - `k`;
  - the sky mask (may be empty);
  - whether to stream, with the scratch dir for a `MergeSpiller`;
  - `loadConcurrency`;
  - the star coverage plane (`misses`; empty on the GPU path, where it computes its own);
  - the debug directory (nullable; see below).

  It returns the refined `MatWrapperRef` (or `M` unchanged). It should reuse what the file
  already has:
  - the file-static `homographyForOffset`, `medianImageFromMats`, `CoverageMisses`,
    `warpInto` and `warpCoverage`;
  - `forEachMergeSource` and `MergeSpiller`, which live in anonymous namespaces in the
    same file, so they're usable from it;
  - `image_cache_load`, an `extern "C"` function in `ImageCache_C.cpp` that the merge
    already calls.
- **Release the star warps first.** On the resident path, release the star warps (the
  `warps` vector) once `M` exists and before the cloud stage starts. The cloud stage
  re-reads the originals through `image_cache_load`, which `pinNeighborDecodes` keeps
  decoded, so that costs no decode.
- **Inputs it needs.** Only the base, `M`, the neighbour files and their homographies,
  the sky mask, and the star coverage plane where one exists. It should *not* depend on
  the star warps still being resident. That keeps it independent of which path produced
  `M`.
- **Call it at the end of every path in `ia_align_and_median_merge`**, after `M` exists:
  1. the batched GPU path (`tryGPUAlignedMerge` returns `M`);
  2. the resident CPU path (`medianImageFromMats`);
  3. the streaming path (`spiller.merge`).
  In the streaming path, spill the cloud-aligned layers through a second `MergeSpiller`
  so peak memory still holds one source at a time.
- **API.** Add `bool cloudAware`, a nullable `MatWrapperRef skyMask` and a nullable
  `const char *cloudDebugDir` to `ia_align_and_median_merge`, after `useGPU`. Update the
  header comment, which documents every parameter at length; match its style. When
  `cloudAware` is false, the function must behave exactly as today and ignore the other
  two.
- **Debug output (required; A4 and §6.5 depend on it).** When `cloudDebugDir` is non-null,
  write:
  - `<dir>/cloud-alpha-<baseFrameIndex>.tif`: 8-bit, α·255, full frame;
  - `<dir>/cloud-velocity-<baseFrameIndex>.txt`: the velocity grid after its median,
    full-res px/frame, one text row per tile row, as `dx` then `dy` blocks with each
    block preceded by a line giving the full-res tile centres of the first row and
    column.
  Production passes null unless `alignmentWriteDebugImages` is on, in which case it
  passes `<tempOutputPath>/cloud-debug`.

### 3.2 Swift bridge (`StarCpp/Sources/StarCppBridge/ImageAligner.swift`)

- Add `cloudAware: Bool = false`, `skyMask: MatWrapper? = nil` and
  `cloudDebugDir: String? = nil` to `alignAndMedianMerge(...)` (line ~203) and pass them
  through.
- Existing callers keep compiling and keep today's behaviour. They are tests:
  - in StarCpp, `MedianMergeTests`, `GPUOpsTests` and `GPUOpsConcurrencyStressTests`;
  - in StarCore, `MergeCoveragePlaneTests` and `AlignedMergeZeroFloorTests`.

### 3.3 Call site (`StarCore/Sources/StarCore/FrameAlignmentProcessor.swift`, ~line 1052)

- Pass `cloudAware: type == .starAligned && mergeConfig.cloudAwareMerge`. That branch
  also serves the moving-camera earth merge, so check the alignment type, not just the
  flag.
- Pass `skyMask: horizonMask?.image.mat`. That branch already loads `horizonMask` via
  `loadOrCreateFinalHorizonMask()` when horizon detection is on; capture it into a local
  before the `NativeWork.run` closure, as the other arguments are.

### 3.4 Config, cache invalidation and CLI

1. **`StarCore/Sources/StarCore/Config.swift`.**
   - `public var cloudAwareMerge: Bool = false`, with a doc comment in the file's style:
     what it does, the measured effect, the cost, why it's off by default.
   - Its `decodeIfPresent` line in the hand-written `init(from:)`. The Mirror-driven
     `ConfigRoundTripTests` fails if that line is missing.
2. **`StarCore/Sources/StarCore/ArtifactInputs.swift`, `alignmentInputs`.**
   - Record `"cloudAwareMerge": "true"` **only when the flag is on**, the same way the
     function already drops `allowEarthAlignment` for a fixed camera
     (`inputs.removeValue(forKey:)`, ~line 322).
   - Why only when on: an old record that lacks a key counts as changed. Adding the key
     unconditionally would make every existing temp dir throw away its alignment,
     outliers and output on the first run after upgrading, even with the flag off.
   - Recorded only when on: flag-off records are unchanged, turning it on invalidates
     (correct), and turning it off again invalidates too (correct, since the record
     differs).
   - The star-aligned images belong to the `alignment` stage, which is why this stage.
   - Known cost: toggling the flag also discards that stage's `homography.db` rows, which
     are recomputed from the cached keypoints. Splitting a separate merge stage is out of
     scope; just say so in the property's doc comment.
   - Tests: extend `ArtifactInputsTests.testSettingsFedToAlignmentInvalidateIt` (~line
     254), and add one asserting the flag-off record equals today's.
3. **CLI.**
   - `cli/Sources/star/StarCli.swift`: `@Flag(name: [.customLong("cloud-aware-merge")], inversion: .prefixedNo, help: ArgumentHelp(localized("cli.help.cloud_aware_merge"))) var cloudAwareMerge: Bool?`.
   - Pass it through `configOverrides`.
   - `cli/Sources/star/ConfigOverrides.swift`: a field plus its apply line (follow
     `useGPUForMerge`).
   - `cli/Tests/starTests/ConfigOverridesTests.swift`: a test.
4. **i18n.** Add `cli.help.cloud_aware_merge` to **all 22** catalogues in
   `StarCore/Sources/StarCore/Resources/Localizations/`. `languages.json` is the
   manifest, not a catalogue.
   - Existing help keys are genuinely translated; do the same.
   - `LocalizationTests.testEveryLanguageHasExactlyTheEnglishKeys` fails on any missing
     key.
   - Each key sits on one line; edit them in place. Don't round-trip the files through a
     JSON writer.

### 3.5 The other clients (originally left out of v1; added when the user asked)

The first version left the other config surfaces out, which meant only the cli could turn the
setting on. The user then asked for it in every client, so it is also in:
- the macOS gui: `ImageSequenceViewModel.cloudAwareMerge` and a "Cloud-Aware Merge" row in
  `ProcessingSettingsView`, outside the expert settings, with the help text under its (i);
- the daemon: `optional bool cloud_aware_merge = 62` in both `star.proto` copies (regenerated
  with `daemon/regen-proto.sh`), and the two lines in `Mapping.swift`;
- the Kotlin desktop client: a `MERGE_FIELDS` row under a "Merge Settings" group in
  `ProcessingSettingsDialog`, outside the expert settings;
- the strings, `ui.cloud_aware_merge`, `ui.merge_settings` and `setting_help.cloud_aware_merge`,
  in all 22 catalogues.

Build the gui, the daemon and `./gradlew checkProtoSync compileKotlin` to prove each.

### 3.6 Memory estimate

The cloud stage adds, on the resident path:
- the cloud-aligned layers (one frame each per neighbour) plus their coverage plane;
- `Rc`;
- several full-res float planes (lumas, low-passes, eM, eC, α): about 4 bytes/px each,
  against 6 bytes/px for a 16-bit RGB frame. Release them eagerly.

Measure it with `--log-op-memory`, which prints `op memory [<op>]: peak …` and
`** OVER RESERVATION by NMB **`.

Then charge for it when the flag is on in `Config.residentBuildExtraMultiplier(...)`
(~line 1967). That term feeds both `effectiveMergeMemoryMultiplier` (~2010) and
`effectiveOutlierMemoryMultiplier` (~2020, used at `FrameGraphBuilder.swift` ~1106),
because outlier ops build the star-aligned image too. Also check the worst-case fallback
constants at `FrameGraphBuilder.swift` ~60–61 (24 for outliers, 21 for merge).

Add cases to `MergeMemoryEstimateTests`. Background reading in project memory:
`memory-gate-ledger-realization`, `merge-streaming-threshold-cost`.

---

## 4. Implementation notes and pitfalls

| Prototype (numpy) | OpenCV |
|---|---|
| `box_blur(a, r)` | 3× `cv::blur(src, dst, Size(2r+1, 2r+1), Point(-1,-1), BORDER_REPLICATE)` (the default border is REFLECT_101, which differs at edges) |
| `downsample(img, 4)` | `cv::resize(..., INTER_AREA)` with an exact factor |
| `median3x3`, `median5` | `cv::medianBlur(ksize 3 / 5)`; ksize 3 and 5 accept `CV_16U` and `CV_32F` |
| `opening(a, 3)`, top-hat | `cv::morphologyEx(MORPH_OPEN / MORPH_TOPHAT, getStructuringElement(MORPH_RECT, {7,7}))` per channel; edge handling differs slightly from the prototype's edge pad |
| `xcorr_shift` | `cv::matchTemplate(TM_CCOEFF_NORMED)` + masked `minMaxLoc` + parabola |
| `upsample_field` + `sample_region` | build `mapx`/`mapy` once per neighbour, then one `cv::remap` |
| `production_merge` | `medianImageFromMats` (it *is* the production kernel) |

Pitfalls:
- **BGR.** OpenCV Mats are BGR; the prototype reads RGB through ImageMagick. Apply the
  luma weights to the right channels.
- **Bit-exactness.** Never test it against the numpy reference. Its warp rounds
  differently from OpenCV's fixed-point bilinear, so its `M` matches production only to a
  mean of 1.6/65535 (about 70% of pixel-channels are not exact). Exactness checks are C++
  flag-on versus C++ flag-off.
- **Threads.** OpenCV here runs the GCD backend and `cv::setNumThreads` is a no-op. Use
  `cv::parallel_for_` over tiles and rows, as the merge kernel does. Total concurrency is
  bounded by `numberOfFramesToProcessConcurrently`, not by you.
- **GPU path.** `useGPUForMerge` makes `M` come from the Metal fused kernel; the cloud
  stage then runs on the CPU afterwards. No Metal work in v1. The GPU merge's output
  differs slightly from the CPU kernel's. For the tolerance, copy the approach of
  `GPUOpsTests.testMedianMergeGPUAgreesWithCPUWithinTheDocumentedTolerance` (~line 272);
  `GPUOps_C.h` explains the difference but gives no number.
- **Determinism.** Everything here is deterministic. Keep it that way: no random
  sampling, and results must not depend on `loadConcurrency` (there's an existing test
  pattern for that).
- **Prediction out of bounds.** Where `round(j·v)` puts the search window off the frame,
  fall back to the prediction itself (the prototype does this).
- **Tests that load from files.** Call `ImageCache.setLoader { MatWrapper.load(fromFilename: $0) }`
  first. Without it every filename source loads as nothing and a merge silently runs on
  the base frame alone. `MedianMergeTests.setUpWithError` shows the pattern.

---

## 5. Phasing

1. **Setup.**
   - The worktree needs the gitignored build artifacts symlinked from the main checkout:
     ```bash
     M=/Users/brian/git/nighttime_timelapse_airplane_remover
     for d in include lib opencv2.framework; do ln -sfn $M/opencv/$d opencv/$d; done
     for d in include lib; do ln -sfn $M/StarDecisionTrees/$d StarDecisionTrees/$d; done
     ln -sfn $M/gui/videos gui/videos   # only for the gui build (gitignored)
     ```
   - Build the cli with `cd cli && swift build`. `cli/star.xcodeproj` hits an `ld`
     assertion with the current Xcode at HEAD; that isn't your bug.
   - Build the gui with `xcodebuild -project gui/star.xcodeproj -scheme star -configuration Debug -derivedDataPath <scratch>/gui-dd CODE_SIGNING_ALLOWED=NO build`.
     Use `-scheme star`, never `-target Star`.
   - Save Appendix A's files into a scratch directory (not the repo) and reproduce the
     reference numbers for frames 28, 30 and 700 before writing any C++ (§6.2).
2. **Correctness (resident CPU path).**
   - Implement Steps A–E over the whole frame; flag plumbing per §3.2–3.4.
   - Build the replay harness (§6.3).
   - Meet §7 A2–A6 on replayed frames.
3. **Every path, cost and tests.**
   - Streaming and GPU paths.
   - Region restriction, defined so it is byte-identical to the full-frame computation
     by construction:
     - The tile grid is always anchored at the frame origin (0,0), never at a region's
       corner.
     - **Active tiles** are the motion tiles (192px step) containing any sky pixel with
       `eM > floor`.
     - Measure motion on the active tiles dilated by 3 tiles in grid units. A full-res
       field value depends on tiles up to 3 steps away: one for the bilinear upsample,
       one for each of the two grid medians.
     - Run the cloud warps, `Rc`, α and the composition over the pixel bounding box of
       the active tiles, dilated by 600px and clipped to the frame.
     - Outside that box, return `M`.
     - Assert restricted == full-frame in a test (§8).
   - Memory estimate (§3.6) and the unit tests in §8.
   - Meet A1, A8 and A9.
4. **End to end.** Run the CLI A/B on fx3-1 frames 1–100 (§6.4), render the comparison
   clip (A7), write up the numbers, open a PR. Don't flip the default.

---

## 6. Verification on real data

### 6.1 The data

| Path | What it is |
|---|---|
| `/sp/tmp/LRT_10_17_2026-fx3-1/LRT_00001.tif` … `LRT_01304.tif` | original frames, 4240×2832, 16-bit RGB |
| `/sp/tmp/star_temp_LRT_10_17_2026-fx3-1/homography.db` | the v0.12.4 run's star homographies |
| `/sp/tmp/star_temp_LRT_10_17_2026-fx3-1/auto-processed/LRT_*.tif` | that run's output: today's behaviour, the baseline |
| `/sp/tmp/star_temp_LRT_10_17_2026-fx3-1/config.json` | that run's settings: static, `automatic(false)`, 8 aligned neighbours, `pixelThreshold` 1.2, `useGPUForMerge` false |

About `homography.db` and file names:
- The schema is `homographies(frame_index, type, data)`, with `type` `star`.
- `data` is `HomographyResultsCodable` JSON. Each entry's `frameIndex` is the
  **absolute** neighbour index; `mappedHomography()` turns those into offsets.
- File names are 1-based: `LRT_00030.tif` is frameIndex 29.

Other notes:
- **Don't write into these directories.** Treat them as read-only inputs; make copies for
  CLI runs. A concurrent GUI session may also be deleting intermediates in temp dirs.
- **What's in the frames.** Frames ~1–95 are dusk with fast cirrus moving 20–80px/frame.
  Frame 700 is clear (Milky Way). Frame 28 has a faint satellite crossing from clear sky
  into cloud.
- **Noise.** It rises ~9× from frame 10 to 60 at constant brightness (ISO ramp): σ_pix is
  42 at frame 10 and 378 at frame 60.
- **Crops.** All the reference crops end at row 1900 or above, well above the horizon
  (its highest point is row 2339), so in a crop the final output equals the star-aligned
  merge.

### 6.2 Running the reference

```bash
cd <scratch>/ref        # the Appendix A files; needs python3 + numpy + ImageMagick 7 (`magick`)
mkdir -p out
python3 proto.py 30 1500 900 1000 1000 out/r30     # ~40s; writes out/r30.npz
python3 combine.py out/r30.npz out/r30.png          # writes out/r30.png (base|star merge|output) and out/r30.png.O2.npy
# expect: CLOUDCORR frac 0.783 current 0.438 proposed 0.971
python3 proto.py 28 1500 900 1000 1000 out/r28 && python3 combine.py out/r28.npz out/r28.png
# expect: CLOUDCORR frac 0.764 current 0.340 proposed 0.972
python3 trailcheck.py out/r28.npz out/r28.png.O2.npy 277 246 985 585
# expect: original +2.69 / current +0.18 / candidate +0.24 pixel sigma
```

`proto.py` arguments are the file index (1-based), the crop `x y w h` in full-res px, and
the output prefix. It loads a 400px margin around the crop for the motion search. It
needs offsets ±2 to exist, so it doesn't handle the first or last two frames.

### 6.3 Replay harness for the C++ (build this first)

Iterating through the full pipeline is slow. Build a test that replays single frames
instead, for example an XCTest in `StarCore/Tests/StarCoreTests` that is skipped unless
an environment variable such as `STAR_CLOUD_REPLAY=1` is set. It should:
1. call `ImageCache.setLoader { MatWrapper.load(fromFilename: $0) }`;
2. **copy** `homography.db` to the scratch dir first (`sqlite3 <src> ".backup <dst>"`)
   and read the copy. StarCore's `HomographyDatabase.read` opens read-write and runs
   WAL/CREATE statements, which would write into the user's temp dir. Read the copy with
   it, or with plain sqlite3;
3. for each requested file index, take that frame's `star` row (frameIndex = file index
   − 1), decode it with `HomographyResultsCodable`, and take `mappedHomography()`;
4. load the sky mask the production call would get. For a static sequence that is the
   merged horizon, `mergedHorizon/LRT_<n>.tif` (what `loadOrCreateFinalHorizonMask`
   returns);
5. call `ImageAligner.alignAndMedianMerge` with the original frames as neighbours,
   `useGPU: false` (the reference run had `useGPUForMerge` off, and the bridge defaults
   to true), the sky mask, and a `cloudDebugDir`, once with `cloudAware: false` and once
   with `true`;
6. write both full-frame results as 16-bit TIFFs to a scratch dir.

The `cloudAware: false` result should be **byte-identical** to `auto-processed/` inside
the reference crops, since the composite only differs near the horizon. That proves the
harness reproduces production. If it isn't, fix the harness before trusting anything
else. The replay recipe is the one in project memory `merge-replay-verification`.

### 6.4 Scoring

```bash
# candidate = your cloudAware:true full-frame TIFF for file index 30
python3 compare.py out/r30.npz out/r30.png.O2.npy <candidate.tif> 1500 900 1000 1000
#   cloud region 0.783 of the crop
#   CLOUDCORR  current 0.438  reference 0.971  candidate <yours>
#   candidate vs reference: mean |d| ...
#   where reference alpha == 0 ...

# candidate = your cloudAware:true full-frame TIFF for file index 28; the last two numbers are the crop origin
python3 trailcheck.py out/r28.npz <candidate.tif> 277 246 985 585 1500 900

# stars kept inside cloud (A6), frame 30 and frame 60
python3 starcheck.py out/r30.npz <candidate.tif> 1500 900
python3 proto.py 60 1200 800 1600 1000 out/r60 && python3 combine.py out/r60.npz out/r60.png
python3 starcheck.py out/r60.npz <candidate-60.tif> 1200 800
#   expect for the reference itself (pass the .O2.npy instead of a TIFF): median 1.01 / 1.00, kept >= 80%: 0.98 / 0.98
```

- **CLOUDCORR** is the correlation, over the reference's α > 0.5 region, between the
  base frame's band-passed (2–24px) luma and the candidate's. 1.0 means the cloud
  structure is the base frame's own. Scoring today's `auto-processed/LRT_00030.tif` this
  way gives exactly the "current" 0.438, which is how the script was validated.
- **trailcheck** finds the satellite line on frame 28 and reports mean luma on the line
  minus beside it, in units of pixel noise. Scoring today's
  `auto-processed/LRT_00028.tif` gives +0.18σ, the "current" figure.
- **Full-pipeline A/B.**
  - Copy frames 1–100 into two fresh, differently named input dirs: temp and output
    paths derive from the input dir name, so reusing a name reuses cached state.
  - Run `cli/.build/debug/star -c automatic --no-use-gpu --log-op-memory -l info <dir>`
    with and without `--cloud-aware-merge`, under `/usr/bin/time -p`. `--no-use-gpu`
    matches the reference run; `useGPUForMerge` defaults to on on this Mac. Read
    CPU-seconds rather than wall clock, which varies ~90s run to run on this machine.
  - Compare with `magick compare -metric AE a.tif b.tif null:`.

### 6.5 The horizon (unverified, check once)

Pick a frame with cloud near the horizon (frames 6–20) and look at the final composite in
a ~400px band around the horizon (its highest point is row 2339), flag on versus off.
- The sky restriction (§2.8) keeps α off the ground, but α's 48px blur still reaches
  into the composite's feather band just above the horizon. Any new seam or ghost ridge
  there must be investigated; the replay technique is in project memory
  `composite-replay-verification`.
- Also confirm with the debug α output that α is 0 everywhere more than 48px below the
  horizon.

---

## 7. Acceptance criteria

| # | Check | Pass when | Reference |
|---|---|---|---|
| A1 | Flag off changes nothing | All existing StarCpp/StarCore/cli tests pass; a CLI run on `test_data/test_a7sii_10` is byte-identical to `develop` (`magick compare -metric AE` = 0 on every frame) | — |
| A2 | Clear sky untouched | Flag on, fx3-1 file indices 600, 700, 800, 1100: the star-aligned output is byte-identical to flag off in the sky interior (rows < 2189, i.e. ≥150px above the horizon's highest point at row 2339, and ≥200px in from the frame edges). Also report max α and max \|Δ\| in the edge band and below the horizon | reference α = 0 on all four crops; full-frame #700 interior max α 0.001, which the 0.01 snap zeroes |
| A3 | Cloud fidelity | Flag on, crop `1200 800 1600 1000`, every file index 6–95: CLOUDCORR ≥ 0.90 on each frame, mean ≥ 0.93 | reference mean 0.949, worst 0.918 (#7); today 0.599 |
| A4 | Cloud region matches | Cloud share (reference α > 0.5) within ±0.10 of the reference for #28, #30, #45, #60; check with your debug α | Appendix B |
| A5 | Trails still removed | #28 trailcheck ≤ +0.5σ | original +2.69σ, today +0.18σ, reference +0.24σ |
| A6 | Stars kept in cloud | `starcheck.py` on #30 (crop `1500 900 1000 1000`) and #60 (crop `1200 800 1600 1000`): median amplitude ratio ≥ 0.90 and ≥ 90% of stars kept at ≥ 80% | reference 1.01 / 0.98 (#30), 1.00 / 0.98 (#60) |
| A7 | Looks right in motion | A triptych clip (original / flag off / flag on) of frames 6–95 on the A3 crop shows no banding, no seams at α edges and no flicker; attach it to the PR | the investigation's clip showed this for the prototype |
| A8 | Cost reported | CPU-seconds and peak op memory per merge, flag on vs off, on fx3-1 frames 1–100 and 600–700; on the clear range the merge op costs ≤ +10% CPU | — |
| A9 | Everything builds | `cd StarCpp && swift test`; `cd StarCore && swift build && swift test`; `cd cli && swift build && swift test`; `cd daemon && swift build`; the gui `xcodebuild` from §5 | — |

If A6 fails, report it before tuning anything; `stars = min(tophat7(M), tophat7(B))` is
the design to revisit.

---

## 8. Unit tests to add

Put these in `StarCpp/Tests/StarCppBridgeTests/CloudAwareMergeTests.swift`, modelled on
`MedianMergeTests.swift` (synthetic Mats via `MatWrapper(width:height:cvType:…)`, temp
TIFFs, `ImageCache.setLoader`). That file's `makeMat` and `assertSourcesLoad` helpers are
`private`, so copy them rather than calling them.

The synthetic frames must be large enough for several fully measured tile rows: at
least 1536×1024 (that's 7×4 tiles), 16-bit, 3-channel, with identity homographies (the
stars are then already aligned). Add noise: a noiseless frame makes `σ_pix` 0 (§2.2 has
the guard, but test realistic input).

1. **Static scene is untouched.** Sky gradient, point stars, noise and a one-frame bright
   streak in the base, nothing moving. Flag on must be byte-identical to flag off.
2. **A moving cloud keeps its shape.** A smooth, band-limited textured blob translating
   +40px/frame in x over point stars, plus a 2px streak in the base only. Assert:
   - in the cloud area, the band-passed correlation with the base is > 0.9 with the flag
     on and clearly lower with it off (this is the banding);
   - the streak's contrast is ~0 either way;
   - star peaks survive in clear and cloudy areas.
3. **Stars behind thin cloud.** A semi-transparent moving cloud over stars: stars in it
   are kept, at least 80% of peak.
4. **Sequence end.** Neighbours on one side only (+1..+4): no crash, cloud kept.
5. **A neighbour without a homography** is skipped, matching today's behaviour.
6. **The ground and the frame edges stay out.** With a sky mask covering the top half,
   cloud motion in the bottom half leaves every row more than 48px below the mask
   boundary byte-identical to flag off. Likewise, pixels more than 48px inside a strip
   that some source's warp doesn't cover are byte-identical. Within 48px, α may be
   non-zero (§2.5 step 5).
7. **Same answer on every path.** Streaming (`streamingThresholdBytes` small) and
   resident are byte-identical with the flag on, and so is every `loadConcurrency`.
8. **Region restriction changes nothing** (§5 step 3): restricted equals full-frame,
   byte for byte.
9. **GPU path.** When `GPUCapability.isAvailable()`, the flag works with `useGPU: true`,
   within the GPU merge's documented tolerance. Otherwise skip.

In StarCore:
- `ConfigRoundTripTests` covers the decode line automatically.
- The `ArtifactInputsTests` additions are in §3.4.
- Add a `MergeMemoryEstimateTests` case for the flag (§3.6).

---

## 9. Known limitations (say these in the PR)

- **Proposed clouds are slightly softer than the original.** The cloud layer is a median
  of a cloud that keeps changing shape, aligned by a coarse field, so the correlation is
  0.92–0.98, not 1.0.
- **Two cloud layers moving differently within one ~384px tile:** one of them wins, and
  the other stays partly banded. The upgrade path is dense optical flow, which needs
  `video` added to `BUILD_LIST` in `opencv/build.sh` and a rebuild of the vendored OpenCV
  on all three platforms.
- **The horizon band** comes from the static 33-frame earth merge and isn't addressed;
  clouds there still smear.
- **Untested:** aurora, moving-camera sequences, any sequence other than fx3-1, frames
  near the sequence ends, 42MP frames.
- **Clouds within ~100px of the horizon** are left as the star merge makes them: the stage only
  works where the merge can be trusted (see 0.1), and the cloud on frame 600's right-hand
  horizon is one it does not touch.
- **Small clouds** (fewer than 6 trusted 384px tiles of coherent motion) do not trigger the
  stage at all; that is the price of the early-out, and what is skipped is a few tiles of banding.
- **A featureless sky is not rejected as well as a real one.** In a synthetic frame with no
  gradient the motion of a cloud spreads to the clear tiles around it, and noise alone gives the
  weight small patches (0.05-0.15) there. Real clear sky never did that on fx3-1 (weight above 0 on
  0.01-0.2% of the region on the frames that ran the stage), but it is the stage's failure mode.
- **Cost on cloud frames is large**: +24 to +32 CPU-s a frame (+51% to +59% of the run) at 12MP, 18 concurrent frames.
- **Colour speckle where α = 0.** The kernel's per-channel selection still produces it
  wherever the stack is incoherent but no cloud motion is found. Choosing one source per
  pixel by luma rank would fix it everywhere, but it changes clear-sky colour noise and is
  a separate change.

---

## 10. Things that went wrong in the prototype

- **Stars hijacked the motion search on starry frames.** From about frame 45 the field
  read 0 over moving cloud. The fix is the zero-shift exclusion plus velocity from ±2.
- **α normalised by per-pixel noise was ~20× too strict.** On an ISO-ramped sequence,
  faint cloud fell back to the banded merge. The fix is the relative test with a
  noise-floor gate.
- **The MAD of the low-passed residual is not a noise estimate.** It measures cloud
  evolution and the missing star field, and came out ~2× the clear-sky value.
- **A grey opening before the low-pass adds noise and bias.** Use the 5×5 median.
- **A top-hat of `M` alone brings the speckles back.** Take the minimum with `B`'s.
- **The search window must fit inside the tile.** R = 48 with a 96 tile overran it.
- **The noise floor needs the ×6 multiplier.** At ×3, the clear frame showed α patches up
  to 0.44.
- **Crops hid the ground.** Every early check used crops well above the horizon. The
  first full-frame run showed α on 40% of a clear frame's ground, hence the sky
  restriction.
- **Byte-identity is a property of the snap, not of the algorithm.** α is a smooth
  function of data and of where the tile grid lands. A crop and a full frame of the same
  sky gave α = 0 and α ≤ 0.001 respectively; the 0.01 snap is what makes "clear sky is
  unchanged" exact.

---

## Appendix A — reference prototype

Save each block below as the named file in one scratch directory, not the repo. Needs
python3, numpy and ImageMagick 7. Paths to the fx3-1 data are hard-coded in `common.py`.

- `proto.py` and `combine.py` are the algorithm (§2).
- `common.py` holds I/O, the homography reader and the production kernel replica;
  `flow.py` holds the motion estimation.
- `compare.py`, `trailcheck.py` and `starcheck.py` are the scoring tools (§6.4, §7).

### `common.py`

```python
"""Shared helpers: read crops of 16-bit RGB TIFFs via magick, warp by stored
star homographies, and reproduce the production sigma-clip merge kernel."""
import json, sqlite3, subprocess, numpy as np

ORIG = "/sp/tmp/LRT_10_17_2026-fx3-1"
TEMP = "/sp/tmp/star_temp_LRT_10_17_2026-fx3-1"
W_FULL, H_FULL = 4240, 2832


def fname(file_index):
    return f"{ORIG}/LRT_{file_index:05d}.tif"


def read_crop(path, x, y, w, h):
    """RGB uint16 crop (h, w, 3); out-of-frame areas padded with zeros."""
    x0, y0 = max(x, 0), max(y, 0)
    x1, y1 = min(x + w, W_FULL), min(y + h, H_FULL)
    out = np.zeros((h, w, 3), np.uint16)
    if x1 <= x0 or y1 <= y0:
        return out
    raw = subprocess.run(
        ["magick", path, "-crop", f"{x1-x0}x{y1-y0}+{x0}+{y0}", "+repage",
         "-depth", "16", "-endian", "LSB", "rgb:-"],
        capture_output=True, check=True).stdout
    a = np.frombuffer(raw, dtype="<u2").reshape(y1 - y0, x1 - x0, 3)
    out[y0 - y:y1 - y, x0 - x:x1 - x] = a
    return out


def star_homographies(base_frame_index):
    """{offset: 3x3 H} mapping neighbour -> base (warpPerspective convention)."""
    con = sqlite3.connect(f"file:{TEMP}/homography.db?mode=ro", uri=True)
    row = con.execute("select data from homographies where frame_index=? and type='star'",
                      (base_frame_index,)).fetchone()
    con.close()
    d = json.loads(row[0])
    hs = {}
    for e in d["neighborHomography"]:
        hs[e["frameIndex"] - base_frame_index] = np.array(e["homography"]).reshape(3, 3)
    return hs


def warp_crop(src, src_x, src_y, H, x, y, w, h):
    """Bilinear-sample src (a crop whose top-left is src_x,src_y in full-frame coords)
    at inv(H)·p for every base pixel p in the (x,y,w,h) window."""
    Hi = np.linalg.inv(H)
    ys, xs = np.mgrid[y:y + h, x:x + w].astype(np.float64)
    den = Hi[2, 0] * xs + Hi[2, 1] * ys + Hi[2, 2]
    sx = (Hi[0, 0] * xs + Hi[0, 1] * ys + Hi[0, 2]) / den - src_x
    sy = (Hi[1, 0] * xs + Hi[1, 1] * ys + Hi[1, 2]) / den - src_y
    x0 = np.floor(sx).astype(int); y0 = np.floor(sy).astype(int)
    fx = (sx - x0)[..., None]; fy = (sy - y0)[..., None]
    sh, sw = src.shape[:2]
    x0c = np.clip(x0, 0, sw - 2); y0c = np.clip(y0, 0, sh - 2)
    s = src.astype(np.float64)
    v = (s[y0c, x0c] * (1 - fx) * (1 - fy) + s[y0c, x0c + 1] * fx * (1 - fy)
         + s[y0c + 1, x0c] * (1 - fx) * fy + s[y0c + 1, x0c + 1] * fx * fy)
    return np.rint(v).astype(np.int64)


def load_stack(base_file_index, x, y, w, h, radius=4, margin=500):
    """Return (offsets, stack[n,h,w,3]) with the base at its own offset 0."""
    hs = star_homographies(base_file_index - 1)
    offsets = sorted(o for o in hs if -radius <= o <= radius)
    offsets = sorted(set(offsets) | {0})
    layers = []
    for o in offsets:
        if o == 0:
            layers.append(read_crop(fname(base_file_index), x, y, w, h).astype(np.int64))
            continue
        src = read_crop(fname(base_file_index + o), x - margin, y - margin,
                        w + 2 * margin, h + 2 * margin)
        layers.append(warp_crop(src, x - margin, y - margin, hs[o], x, y, w, h))
    return offsets, np.stack(layers)


def production_merge(stack, k=1.2):
    """The shipped kernel (no coverage misses): per pixel-channel, sort, clip values
    >= mean + k*std (population), output sorted[(0 + maxIndex)//2].
    Returns (output, source_index) where source_index is the stack layer chosen."""
    n = stack.shape[0]
    order = np.argsort(stack, axis=0, kind="stable")
    srt = np.take_along_axis(stack, order, axis=0).astype(np.float64)
    mean = srt.mean(axis=0)
    std = srt.std(axis=0)
    thr = mean + k * std
    below = (srt < thr).sum(axis=0)  # sorted -> accepted values are a prefix
    max_index = np.where(below > 0, below - 1, n)
    idx = np.clip(max_index // 2, 0, n - 1)
    out = np.take_along_axis(srt, idx[None], axis=0)[0]
    src = np.take_along_axis(order, idx[None], axis=0)[0]
    return out.astype(np.int64), src


def to8(img, lo, hi):
    return (np.clip((img - lo) / (hi - lo), 0, 1) * 255).astype(np.uint8)


def save_rgb(path, img8):
    h, w = img8.shape[:2]
    subprocess.run(["magick", "-size", f"{w}x{h}", "-depth", "8", "rgb:-", path],
                   input=np.ascontiguousarray(img8).tobytes(), check=True)
```

### `flow.py`

```python
"""Coarse cloud-motion estimation between star-aligned layers, in numpy.

Tile cross-correlation of band-passed, downsampled luma: stars are suppressed by
the downsample + small blur, the sky gradient by the large blur, so what is left to
correlate is cloud structure.  A tile with no cloud correlates best at zero shift,
which is the star alignment already applied."""
import numpy as np

LUMA = np.array([0.2126, 0.7152, 0.0722])


def box_blur(a, r):
    """Separable box blur of radius r, edge-replicated, applied 3x ~ gaussian."""
    for _ in range(3):
        for ax in (0, 1):
            p = np.pad(a, [(r + 1, r) if i == ax else (0, 0) for i in range(a.ndim)], mode="edge")
            c = np.cumsum(p, axis=ax, dtype=np.float64)
            hi = np.take(c, np.arange(2 * r + 1, c.shape[ax]), axis=ax)
            lo = np.take(c, np.arange(0, c.shape[ax] - 2 * r - 1), axis=ax)
            a = (hi - lo) / (2 * r + 1)
    return a


def downsample(img, f):
    h, w = img.shape[0] // f * f, img.shape[1] // f * f
    return img[:h, :w].reshape(h // f, f, w // f, f, *img.shape[2:]).mean(axis=(1, 3))


def median3x3(a):
    p = np.pad(a, 1, mode="edge")
    return np.median(np.stack([p[i:i + a.shape[0], j:j + a.shape[1]] for i in range(3) for j in range(3)]), axis=0)


def bandpass_luma(layer, f=4):
    # stars are ~1px after the downsample; a 3x3 median removes them, cloud stays
    l = median3x3(downsample(layer @ LUMA, f))
    return box_blur(l, 1) - box_blur(l, 12)


def xcorr_shift(a, b, max_shift, zero_at=None, exclude=0):
    """Integer+parabolic shift s maximising sum a(x) * b(x + s) (b sampled at x+s
    matches a).  Normalised cross-correlation via FFT; returns (dy, dx, peak)."""
    a = a - a.mean(); b = b - b.mean()
    wy = np.hanning(a.shape[0])[:, None]; wx = np.hanning(a.shape[1])[None, :]
    a = a * wy * wx; b = b * wy * wx
    F = np.fft.rfft2(a).conj() * np.fft.rfft2(b)
    c = np.fft.irfft2(F, s=a.shape)
    c = np.fft.fftshift(c)
    cy, cx = a.shape[0] // 2, a.shape[1] // 2
    win = c[cy - max_shift:cy + max_shift + 1, cx - max_shift:cx + max_shift + 1]
    sel = win
    if exclude > 0 and zero_at is not None:
        # Stars sit at exactly zero shift after star alignment.  Look for the best
        # *other* motion; whether it really is cloud is decided downstream by
        # whether the cloud-aligned merge explains the base better.
        yy, xx = np.mgrid[-max_shift:max_shift + 1, -max_shift:max_shift + 1]
        near0 = (yy - zero_at[0]) ** 2 + (xx - zero_at[1]) ** 2 < exclude ** 2
        sel = np.where(near0, -np.inf, win)
    iy, ix = np.unravel_index(np.argmax(sel), sel.shape)
    norm = np.sqrt((a * a).sum() * (b * b).sum()) + 1e-12
    peak = win[iy, ix] / norm

    def para(m, z, p):
        d = m - 2 * z + p
        return 0.0 if d == 0 else 0.5 * (m - p) / d
    sy = sx = 0.0
    if 0 < iy < win.shape[0] - 1: sy = para(win[iy - 1, ix], win[iy, ix], win[iy + 1, ix])
    if 0 < ix < win.shape[1] - 1: sx = para(win[iy, ix - 1], win[iy, ix], win[iy, ix + 1])
    return iy - max_shift + sy, ix - max_shift + sx, peak


def tile_motion(base_bp, nb_bp, tile=96, step=48, max_shift=40, predict=None, exclude=0):
    """Per-tile shift (in downsampled px) such that nb(x + d) ~ base(x).
    `predict` (grid of dy,dx) recentres the search window per tile."""
    H, W = base_bp.shape
    ys = list(range(0, H - tile + 1, step)); xs = list(range(0, W - tile + 1, step))
    d = np.zeros((len(ys), len(xs), 2)); pk = np.zeros((len(ys), len(xs)))
    for i, y in enumerate(ys):
        for j, x in enumerate(xs):
            py, px = (0, 0) if predict is None else np.rint(predict[i, j]).astype(int)
            y2, x2 = y + py, x + px
            if y2 < 0 or x2 < 0 or y2 + tile > H or x2 + tile > W:
                d[i, j] = (py, px); continue
            a = base_bp[y:y + tile, x:x + tile]; b = nb_bp[y2:y2 + tile, x2:x2 + tile]
            dy, dx, p = xcorr_shift(a, b, max_shift, zero_at=(-py, -px), exclude=exclude)
            d[i, j] = (py + dy, px + dx); pk[i, j] = p
    centres = (np.array(ys) + tile / 2, np.array(xs) + tile / 2)
    return d, pk, centres


def median3(grid):
    """3x3 vector-ish median filter (componentwise) of a tile grid, to drop outliers."""
    p = np.pad(grid, ((1, 1), (1, 1), (0, 0)), mode="edge")
    stack = np.stack([p[i:i + grid.shape[0], j:j + grid.shape[1]] for i in range(3) for j in range(3)])
    return np.median(stack, axis=0)


def upsample_field(d, centres, f, H, W):
    """Bilinear-interpolate a tile-centre grid of shifts to a full-res (H,W,2) field,
    scaled from downsampled px to full-res px."""
    cy, cx = centres[0] * f, centres[1] * f
    yy = np.arange(H) + 0.5; xx = np.arange(W) + 0.5
    def interp_axis(vals, centres_, coords, axis):
        idx = np.clip(np.searchsorted(centres_, coords) - 1, 0, len(centres_) - 2)
        t = np.clip((coords - centres_[idx]) / (centres_[idx + 1] - centres_[idx]), 0, 1)
        a = np.take(vals, idx, axis=axis); b = np.take(vals, idx + 1, axis=axis)
        shape = [1] * vals.ndim; shape[axis] = len(coords)
        t = t.reshape(shape)
        return a * (1 - t) + b * t
    r = interp_axis(d, cy, yy, 0)
    r = interp_axis(r, cx, xx, 1)
    return r * f


def sample(layer, field):
    """layer(x + field(x)) by bilinear interpolation (edge-clamped)."""
    H, W = layer.shape[:2]
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float64)
    sy = ys + field[..., 0]; sx = xs + field[..., 1]
    y0 = np.clip(np.floor(sy).astype(int), 0, H - 2); x0 = np.clip(np.floor(sx).astype(int), 0, W - 2)
    fy = np.clip(sy - y0, 0, 1)[..., None]; fx = np.clip(sx - x0, 0, 1)[..., None]
    return (layer[y0, x0] * (1 - fx) * (1 - fy) + layer[y0, x0 + 1] * fx * (1 - fy)
            + layer[y0 + 1, x0] * (1 - fx) * fy + layer[y0 + 1, x0 + 1] * fx * fy)
```

### `proto.py`

```python
"""Reference prototype, step 1 of 2: star merge M and cloud-aligned merge Rc for one
frame on a crop.  usage: proto.py <file index, 1-based> <x> <y> <w> <h> <out> [margin]

Needs offsets +-2 to exist (it is not written for the first/last two frames).

Writes <out>.npz: the star-aligned stack (Sin), the cloud-aligned stack (C), the
production-kernel merge of each (M, Rc), and the tile motion grids."""
import sys, time, numpy as np
from common import *
from flow import *

base = int(sys.argv[1]); x, y, w, h = map(int, sys.argv[2:6]); out = sys.argv[6]
m = int(sys.argv[7]) if len(sys.argv) > 7 else 400
F = 4
t0 = time.time()
offsets, S = load_stack(base, x - m, y - m, w + 2 * m, h + 2 * m)
S = S.astype(np.float32)
i0 = offsets.index(0)
print("loaded", S.shape, "%.1fs" % (time.time() - t0))

bp = [bandpass_luma(S[k], F) for k in range(len(offsets))]
by_off = dict(zip(offsets, range(len(offsets))))
fields = {}
grids = {}
# velocity from offsets +-2 (twice the displacement of +-1, so slow cloud clears the
# excluded zero-shift star peak), then every neighbour searched near j*v
EX = 2  # downsampled px: zero-shift exclusion radius
d_p, pk_p, centres = tile_motion(bp[i0], bp[by_off[2]], max_shift=46, exclude=EX)
d_m, pk_m, _ = tile_motion(bp[i0], bp[by_off[-2]], max_shift=46, exclude=EX)
v = median3((d_p - d_m) / 4)
for o in offsets:
    if o == 0: continue
    d, pk, _ = tile_motion(bp[i0], bp[by_off[o]], max_shift=16, predict=o * v, exclude=EX)
    d = median3(d)
    grids[o] = (d, pk)
    fields[o] = upsample_field(d, centres, F, h + 2 * m, w + 2 * m)
print("motion %.1fs" % (time.time() - t0))
print("velocity (full-res px/frame) per tile, dx:\n", np.round(v[..., 1] * F).astype(int))
print("dy:\n", np.round(v[..., 0] * F).astype(int))

# cloud-aligned layers over the inner crop only
def sample_region(layer, field):
    ys, xs = np.mgrid[m:m + h, m:m + w].astype(np.float64)
    f = field[m:m + h, m:m + w]
    sy = ys + f[..., 0]; sx = xs + f[..., 1]
    H, W = layer.shape[:2]
    y0 = np.clip(np.floor(sy).astype(int), 0, H - 2); x0 = np.clip(np.floor(sx).astype(int), 0, W - 2)
    fy = np.clip(sy - y0, 0, 1)[..., None]; fx = np.clip(sx - x0, 0, 1)[..., None]
    return (layer[y0, x0] * (1 - fx) * (1 - fy) + layer[y0, x0 + 1] * fx * (1 - fy)
            + layer[y0 + 1, x0] * (1 - fx) * fy + layer[y0 + 1, x0 + 1] * fx * fy)

Sin = S[:, m:m + h, m:m + w]
C = np.stack([Sin[k] if o == 0 else sample_region(S[k], fields[o]) for k, o in enumerate(offsets)])
del S
M, _ = production_merge(Sin.astype(np.int64))
Rc, _ = production_merge(np.rint(C).astype(np.int64))
print("merged %.1fs" % (time.time() - t0))
u16 = lambda a: np.clip(np.rint(a), 0, 65535).astype(np.uint16)
np.savez(out, offsets=np.array(offsets), Sin=u16(Sin), C=u16(C), M=u16(M), Rc=u16(Rc),
         v=v, centres0=centres[0], centres1=centres[1],
         grids=np.array([grids[o][0] for o in offsets if o != 0]))
```

### `combine.py`

```python
"""Reference prototype, step 2 of 2: alpha, star layer and the final output.
usage: combine.py <proto npz> <out png> [r=3] [LO=0.2] [HI=0.5] [FLOORK=6]

In cloud regions the output is the cloud-aligned merge (trails removed
statistically, as today) plus the star layer lifted out of the star-aligned merge
with a small top-hat (point sources only; the star merge's cloud banding is broad
and does not survive a 7px opening).  Writes <out png> (base | star merge | output)
and <out png>.O2.npy (the output, float, RGB)."""
import sys, numpy as np
from numpy.lib.stride_tricks import sliding_window_view as swv
from common import to8, save_rgb
from flow import box_blur, LUMA


def morph(a, r, op):
    """Square (2r+1)^2 min/max filter, separable."""
    p = np.pad(a, r, mode="edge")
    return op(swv(op(swv(p, 2 * r + 1, axis=0), axis=-1), 2 * r + 1, axis=1), axis=-1)


def opening(a, r):
    return morph(morph(a, r, np.min), r, np.max)


def median5(a):
    w = swv(np.pad(a, 2, mode="edge"), (5, 5))
    return np.median(w.reshape(a.shape[0], a.shape[1], 25), axis=-1)


def alpha_for(B, M, Rc, LO=0.2, HI=0.5, FLOORK=6.0):
    """Cloud weight, 0..1, and the star-robust per-pixel noise it was gated with."""
    LB, LM, LC = B @ LUMA, M @ LUMA, Rc @ LUMA
    # Compare cloud structure only, on luma with stars taken out by a 5x5 median (the
    # cloud-aligned merge has no stars, so with them left in base-minus-cloud-merge
    # carries the blurred star field), then low-passed.
    lp = lambda a: box_blur(median5(a), 6)
    lpB = lp(LB)
    eM = box_blur(np.abs(lpB - lp(LM)), 24)
    eC = box_blur(np.abs(lpB - lp(LC)), 24)
    # Relative test: how much of the star merge's error does the cloud merge remove.
    # Equal errors (clear sky, where the motion field found nothing real) give 0; the
    # cloud merge can only lose there, since it has no stars.  Gated by a noise floor
    # so two near-zero errors cannot make a large ratio: per-pixel noise from
    # horizontal differences (star-robust), times ~0.05 for what the low-pass leaves.
    d1 = np.diff(LB, axis=1)
    sigma_pix = 1.4826 * np.median(np.abs(d1 - np.median(d1))) / np.sqrt(2)
    floor = FLOORK * 0.05 * sigma_pix
    rel = 1 - eC / np.maximum(eM, 1e-6)
    alpha = np.clip((rel - LO) / (HI - LO), 0, 1) * np.clip((eM - floor) / floor, 0, 1)
    return box_blur(alpha, 16), sigma_pix


def compose(B, M, Rc, alpha, r=3):
    # A star is in both the base and the star merge.  The star merge's own small
    # speckles (per-channel picks from different frames inside the cloud patchwork)
    # are not in the base, and a trail in the base is not in the star merge, so the
    # smaller of the two top-hats keeps stars and drops both.
    tophat = lambda a: np.stack([a[..., c] - opening(a[..., c], r) for c in range(3)], axis=-1)
    stars = np.minimum(tophat(M), tophat(B))
    cloudLayer = np.stack([opening(Rc[..., c], r) for c in range(3)], axis=-1)
    return (1 - alpha[..., None]) * M + alpha[..., None] * (cloudLayer + stars)


if __name__ == "__main__":
    d = np.load(sys.argv[1]); out = sys.argv[2]
    r = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    LO = float(sys.argv[4]) if len(sys.argv) > 4 else 0.2
    HI = float(sys.argv[5]) if len(sys.argv) > 5 else 0.5
    FLOORK = float(sys.argv[6]) if len(sys.argv) > 6 else 6.0
    offsets = list(d["offsets"]); i0 = offsets.index(0)
    B = d["Sin"][i0].astype(np.float64); M = d["M"].astype(np.float64); Rc = d["Rc"].astype(np.float64)
    alpha, sigma_pix = alpha_for(B, M, Rc, LO, HI, FLOORK)
    O2 = compose(B, M, Rc, alpha, r)
    np.save(out + ".O2.npy", O2)
    LB, LM = B @ LUMA, M @ LUMA
    dm = np.abs(O2 @ LUMA - LM)
    print("alpha mean %.3f, >0.05 on %.3f, >0.5 on %.3f; |O2-M| luma mean %.1f p99.9 %.0f"
          % (alpha.mean(), (alpha > 0.05).mean(), (alpha > 0.5).mean(), dm.mean(), np.percentile(dm, 99.9)))
    print("noise floor %.1f (robust pixel sigma %.1f)" % (FLOORK * 0.05 * sigma_pix, sigma_pix))
    # cloud fidelity: band-passed (2..24px) luma correlation with the base, inside the
    # cloud region only.  1.0 = the cloud structure is the base frame's own.
    bpass = lambda a: box_blur(a, 2) - box_blur(a, 24)
    sel = alpha > 0.5
    if sel.sum() > 1000:
        corr = lambda a: np.corrcoef(bpass(LB)[sel], bpass(a)[sel])[0, 1]
        print("CLOUDCORR frac %.3f current %.3f proposed %.3f" % (sel.mean(), corr(LM), corr(O2 @ LUMA)))
    else:
        print("CLOUDCORR frac %.3f" % sel.mean())
    lo, hi = np.percentile(B[..., 1], 1), np.percentile(B[..., 1], 99.7)
    save_rgb(out, np.concatenate([to8(B, lo, hi), to8(M, lo, hi), to8(O2, lo, hi)], axis=1))
```

### `compare.py`

```python
"""Score a full-frame output TIFF (e.g. the C++ star-aligned merge) against the
reference prototype on the same crop.

usage: compare.py <proto npz> <reference O npy> <candidate.tif> <x> <y> <w> <h>

<proto npz> and <reference O npy> come from proto.py / combine.py run on the same
crop (combine.py writes <out png>.O2.npy).  The cloud region is the reference's
alpha > 0.5, recomputed here exactly as combine.py does, so every candidate is
scored on the same pixels."""
import sys, numpy as np
from common import read_crop
from flow import box_blur, LUMA
from combine import alpha_for

d = np.load(sys.argv[1]); O_ref = np.load(sys.argv[2])
x, y, w, h = map(int, sys.argv[4:8])
cand = read_crop(sys.argv[3], x, y, w, h).astype(np.float64)
offsets = list(d["offsets"]); i0 = offsets.index(0)
B = d["Sin"][i0].astype(np.float64); M = d["M"].astype(np.float64); Rc = d["Rc"].astype(np.float64)
alpha, sigma_pix = alpha_for(B, M, Rc)
LB = B @ LUMA
bpass = lambda a: box_blur(a, 2) - box_blur(a, 24)
sel = alpha > 0.5
corr = lambda a: np.corrcoef(bpass(LB)[sel], bpass(a @ LUMA)[sel])[0, 1]
print("cloud region %.3f of the crop" % sel.mean())
print("CLOUDCORR  current %.3f  reference %.3f  candidate %.3f" % (corr(M), corr(O_ref), corr(cand)))
dl = np.abs(cand @ LUMA - O_ref @ LUMA)
print("candidate vs reference: mean |d| luma %.1f = %.3f pixel sigma; p99 %.0f; exact pixels %.3f"
      % (dl.mean(), dl.mean() / sigma_pix, np.percentile(dl, 99), (np.abs(cand - np.rint(O_ref)) == 0).all(axis=-1).mean()))
clear = alpha == 0
if clear.any():
    dc = np.abs(cand - M)[clear]
    print("where reference alpha == 0 (%.3f of crop): candidate == star merge on %.4f of pixel-channels, max |d| %.0f"
          % (clear.mean(), (dc == 0).mean(), dc.max()))
```

### `trailcheck.py`

```python
"""Trail-removal check for one frame crop.

usage: trailcheck.py <proto npz> <candidate> <ax> <ay> <bx> <by> [<crop x> <crop y>]

<candidate> is either combine.py's <out png>.O2.npy (already cropped), or a
full-frame TIFF, in which case pass the crop origin the npz was made with.
ax ay bx by are rough trail endpoints in crop px.

Finds the trail as the straight line (searched over angle and offset around the
rough endpoints) along which the base's thin residual over the star merge is
largest, then reports, for base / star merge / candidate, the mean luma on the
line minus the mean 8-10px either side.  Present trail: clearly positive.
Removed: ~0."""
import sys, numpy as np
from common import read_crop
from flow import box_blur, LUMA
d = np.load(sys.argv[1]); offs = list(d['offsets']); i0 = offs.index(0)
B = d['Sin'][i0].astype(float) @ LUMA; M = d['M'].astype(float) @ LUMA
if sys.argv[2].endswith(".npy"):
    O = np.load(sys.argv[2]) @ LUMA
else:
    cx, cy = int(sys.argv[7]), int(sys.argv[8])
    O = read_crop(sys.argv[2], cx, cy, B.shape[1], B.shape[0]).astype(float) @ LUMA
a0, a1 = np.array(sys.argv[3:5], float), np.array(sys.argv[5:7], float)  # rough endpoints, crop px
H, W = B.shape
d1 = np.diff(B, axis=1); s = 1.4826*np.median(np.abs(d1-np.median(d1)))/np.sqrt(2)
thin = (B - M) - box_blur(B - M, 4)          # thin residual: a trail, not cloud
ts = np.linspace(0.05, 0.95, 1500)
c0 = (a0 + a1) / 2; L = np.linalg.norm(a1 - a0); ang0 = np.arctan2(*(a1 - a0)[::-1])
def samples(img, c, ang, off):
    u = np.array([np.cos(ang), np.sin(ang)]); n = np.array([-u[1], u[0]])
    q = c[None] + ((ts - 0.5) * L)[:, None] * u[None] + off * n[None]
    xi = np.clip(np.rint(q[:, 0]).astype(int), 0, W - 1); yi = np.clip(np.rint(q[:, 1]).astype(int), 0, H - 1)
    return img[yi, xi]
best = (-1e18, None)
for ang in ang0 + np.radians(np.arange(-3, 3.001, 0.05)):
    for off in np.arange(-45, 45.01, 0.5):
        v = samples(thin, c0, ang, off).mean()
        if v > best[0]: best = (v, (ang, off))
ang, off = best[1]
print("trail angle %.2f deg (rough %.2f), offset %.1f px, thin residual %.1f" % (np.degrees(ang), np.degrees(ang0), off, best[0]))
def contrast(img):
    on = np.mean([samples(img, c0, ang, off + o) for o in (-0.5, 0, 0.5)], axis=0)
    side = np.mean([samples(img, c0, ang, off + o) for o in (-10, -9, -8, 8, 9, 10)], axis=0)
    return (on - side).mean()
for name, img in (("original", B), ("current", M), ("candidate", O)):
    c = contrast(img)
    print(f"{name:9s} on-trail minus beside: {c:7.1f} luma = {c/s:+.2f} pixel sigma (sigma {s:.0f})")
```


### `starcheck.py`

```python
"""Star-retention check inside the cloud region (§7 A6).

usage: starcheck.py <proto npz> <candidate> [<crop x> <crop y>]

<candidate> is either combine.py's <out png>.O2.npy (already cropped) or a
full-frame TIFF, in which case pass the crop origin the npz was made with.

Picks the 50 brightest stars of the star merge M inside the reference cloud region
(alpha > 0.5): local maxima of M's 7x7 top-hat on luma, at least 12px from the crop
border and 10px from each other.  A star's amplitude is the 3x3 maximum around the
peak minus the median of the 5..8px annulus around it.  Reports, for the reference
output and the candidate, amplitude / M's amplitude: the median, and the fraction of
stars kept at >= 80%."""
import sys, numpy as np
from common import read_crop
from flow import LUMA
from combine import alpha_for, opening

d = np.load(sys.argv[1]); offs = list(d["offsets"]); i0 = offs.index(0)
B = d["Sin"][i0].astype(np.float64); M = d["M"].astype(np.float64); Rc = d["Rc"].astype(np.float64)
alpha, _ = alpha_for(B, M, Rc)
if sys.argv[2].endswith(".npy"):
    cand = np.load(sys.argv[2])
else:
    cand = read_crop(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), B.shape[1], B.shape[0]).astype(np.float64)
LM, LC = M @ LUMA, cand @ LUMA
th = LM - opening(LM, 3)
H, W = th.shape
pad = np.pad(th, 1, mode="edge")
locmax = th >= np.max(np.stack([pad[i:i + H, j:j + W] for i in range(3) for j in range(3)]), axis=0)
ok = locmax & (alpha > 0.5)
ok[:12] = ok[-12:] = False; ok[:, :12] = ok[:, -12:] = False
ys, xs = np.nonzero(ok)
order = np.argsort(-th[ys, xs])
picked = []
for k in order:
    y, x = ys[k], xs[k]
    if all((y - py) ** 2 + (x - px) ** 2 >= 100 for py, px in picked):
        picked.append((y, x))
    if len(picked) == 50:
        break
yy, xx = np.mgrid[-8:9, -8:9]; ring = (yy ** 2 + xx ** 2 >= 25) & (yy ** 2 + xx ** 2 <= 64)
def amplitude(L, y, x):
    return L[y - 1:y + 2, x - 1:x + 2].max() - np.median(L[y - 8:y + 9, x - 8:x + 9][ring])
aM = np.array([amplitude(LM, y, x) for y, x in picked])
aC = np.array([amplitude(LC, y, x) for y, x in picked])
r = aC / np.maximum(aM, 1e-6)
print("stars measured %d (cloud region %.3f of crop)" % (len(picked), (alpha > 0.5).mean()))
print("candidate / star merge amplitude: median %.2f, kept >= 80%%: %.2f" % (np.median(r), (r >= 0.8).mean()))
```

## Appendix B — reference numbers

All produced by the Appendix A code at the parameters in §2.7. "Current" is the
production-kernel star merge; "proposed" is the reference output.

**Single frames**

| File index | Crop (x y w h) | Cloud share (α > 0.5) | CLOUDCORR current | CLOUDCORR proposed | Notes |
|---|---|---|---|---|---|
| 28 | 1500 900 1000 1000 | 0.764 | 0.340 | 0.972 | trailcheck: original +2.69σ, current +0.18σ, proposed +0.24σ (σ 108) |
| 30 | 1500 900 1000 1000 | 0.783 | 0.438 | 0.971 | noise floor 35.4, σ_pix 117.9 |
| 45 | 1200 800 1600 1000 | 0.342 | 0.566 | 0.958 | σ_pix 228 |
| 60 | 1200 800 1600 1000 | 0.500 | 0.811 | 0.941 | σ_pix 378 |
| 700 | 1200 800 1600 1000 | 0.000 | — | — | clear; α = 0 everywhere, output == star merge |
| 600, 800, 1100 | 1200 800 1600 1000 | 0.000 | — | — | clear; α = 0 everywhere (σ_pix 1428 / 1448 / 1491) |

**Full frames** (crop `0 0 4240 2832`, margin 0; the prototype's edge handling is crude,
see §2.8). The sky/ground split uses `horizonReference/reference.tiff`.

| File index | Sky: α > 0 / α > 0.5 | Ground: α > 0 / α > 0.5 | Sky interior (rows < 2189, ≥200px from edges) | CLOUDCORR current → proposed |
|---|---|---|---|---|
| 700 (clear) | 0.022 / 0.001 | 0.397 / 0.089 | max α 0.001 on 0.14% of pixels; max \|O − M\| 0.00σ | (region is ground and edges) |
| 30 (cloud) | 0.800 / 0.454 | 0.999 / 0.857 | — | 0.797 → 0.983 (the region includes ground, which inflates "current") |

The ground figures are why the guide restricts α to the sky (§2.8).

**Frames 6–95, crop 1200 800 1600 1000** (every 5th frame shown, plus the worst):
mean CLOUDCORR current 0.599 → proposed 0.949; worst proposed 0.918 at #7.

| File index | Cloud share | Current | Proposed |
|---|---|---|---|
| 6 | 0.50 | 0.201 | 0.930 |
| 7 | 0.53 | 0.217 | 0.918 |
| 11 | 0.54 | 0.247 | 0.949 |
| 16 | 0.57 | 0.195 | 0.949 |
| 21 | 0.67 | 0.219 | 0.949 |
| 26 | 0.67 | 0.293 | 0.949 |
| 31 | 0.56 | 0.303 | 0.963 |
| 36 | 0.60 | 0.367 | 0.965 |
| 41 | 0.60 | 0.543 | 0.968 |
| 46 | 0.46 | 0.647 | 0.957 |
| 51 | 0.47 | 0.756 | 0.942 |
| 56 | 0.53 | 0.822 | 0.950 |
| 61 | 0.47 | 0.845 | 0.945 |
| 66 | 0.39 | 0.816 | 0.942 |
| 71 | 0.41 | 0.837 | 0.943 |
| 76 | 0.42 | 0.856 | 0.951 |
| 81 | 0.33 | 0.870 | 0.952 |
| 86 | 0.34 | 0.899 | 0.961 |
| 91 | 0.24 | 0.870 | 0.947 |

The "current" column rises through the night because the cloud gets fainter relative to
noise, so the banding costs less correlation. The proposed column holds steady.

**Velocity grids, for orientation, not tile-for-tile matching.** These are full-res
px/frame per tile after the 3×3 grid median. Your full-frame tile grid starts at (0,0) and
won't line up with these crop-relative tiles; compare velocities at nearby positions.

Frame 30 (crop 1500 900 1000 1000, margin 400). Tile centres: x = 1292 + 192·col,
y = 692 + 192·row.

```
dx:
 [[ 21  -2  -2  50  50  34  32  37]
  [ -2   2  12  49  34  47  32  32]
  [-11   2  12  24  24  49  32  32]
  [ 12  12  24  45  45  46  40  40]
  [ 41  41  41  36  36  45  33  32]
  [ 39  39  36  35  35  33  32  32]
  [ 27  27  25  28  29  29  28  24]
  [ 16  18  18  21  21  21  21  18]]
dy:
 [[ -2  -2   1   1  20  25  35  29]
  [-20  -7   1   3  15  16  25  29]
  [ -7  -3   1   3   7  15  16  16]
  [  8   5   5   7   8  13  13  13]
  [  8   5   4   3   7   9  11  11]
  [  3   3   3   3   4   6   8  11]
  [ -1   0   2   3   3   4   5   6]
  [ -1  -1   0   2   3   3   4   4]]
```

Frame 60 (crop 1200 800 1600 1000, margin 400). Tile centres: x = 992 + 192·col,
y = 592 + 192·row. The near-zero entries at the top right are clear sky, where Step D
rejects the field.

```
dx:
 [[ 28  28  28  44  44   2 -12   0   0   0  -1]
  [ 28  26  28  37  37   8   2   1   1   0  -1]
  [ 26  17  28  37  37  26  24   1   1   1   0]
  [  9  12  17  28  28  28  31  24  30   1  30]
  [ 20  20  28  40  40  40  38  35  34  23  23]
  [ 20  20  24  29  40  40  38  35  29  24  23]
  [ 23  20  20  24  29  29  29  25  24  23  19]
  [ 20  20  20  20  24  24  21  21  21  19  19]]
dy:
 [[-25 -25 -25 -25  12  13  12   4   1   0   0]
  [-24 -24 -21 -17  -4  12   4   1   1   1   0]
  [-23 -15   3  -4  -6  -6   4   2   3   2   2]
  [-15  -4  -4  -4  -6   5   5   3   4   3   8]
  [ -6  -4   3   4   5   5   5   5   7  11  14]
  [ -6  -5  -4   2   4   5   5   5   7   8   8]
  [ -6  -3   0   2   2   3   3   4   7   7   8]
  [  0   0   0   0   0   2   3   4   4   6   6]]
```
