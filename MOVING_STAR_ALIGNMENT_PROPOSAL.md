# Moving-sequence star alignment under moonlight

Why `LRT_10_17_2026-a9-1` lost stars on frame 69 and about 600 other frames, and how to
fix it. Everything here was measured against the run's own temp dir
(`/sp/tmp/star_temp_10_17_2026-a9-1`, Star 0.12.4) and the source frames, with throwaway
tools described at the end.

## Summary

- **The sky homographies were wrong from the moment they were measured.** The gap-fill
  repair is not to blame. On frame 69 the fits are off by 1.5–7.5px median, up to 19px.
  That is against an independent fit of more than 4000 star centroids, which a single
  homography matches at 0.27px RMS.
- **Cause 1: SIFT keypoints on an artificial edge.** `toGray8UWithMask` blacks out
  everything outside the sky mask, which leaves a bright-sky-to-black step along the
  eroded horizon. Under moonlight the sky just above the horizon is the brightest part of
  the frame, so this step is the strongest structure SIFT sees. The step follows the
  horizon mask, so it moves with the **ground**, not the stars. On frame 69 it holds 28%
  of the keypoints, about 60% of the descriptor matches and 15–68% of the RANSAC inliers.
- **Cause 2: RANSAC's 10px tolerance with few star inliers.** Even without the step,
  frame 69 has only 20–60 star inliers per pair, and at 10px three of the eight offsets
  still lock onto a wrong consensus.
- **The repair could not save it.** In frames 100–600, 95% of measurements were biased the
  same way, so every "good" donor was wrong too. The stored (repaired) matrices are as far
  from the truth as the measured ones.
- **Fixing both causes in the measurement** brings frame 69 to 0.10–0.38px median error.
  Frames condemned by validation drop from **621 to 102**, and the moonlit stretch goes
  from 422 repairs to **2**. In the merge simulation, the share of each star's brightness
  kept on frame 69 goes from **0.27 to 0.86**, against 0.87 for perfect alignment.
- **What is left is twilight** (frames 0–60 and 1800+), where SIFT gets only 7–18 inliers.
  Matching star centroids handles it: frame 30 gets about 4000 pairs at 0.36px. That is
  also the answer to "estimate better than just replacing": seed a guided measurement from
  the donor instead of copying the donor.

## The symptom, measured

The final frame 69 keeps stars only in the top-right (around Andromeda). The rest of the
sky is erased: the stars are missing from the merge, so the outlier pass treats each real
star as an outlier and paints it out.

A simulated merge of frame 69 measures how much of each star survives (DoG peak in the
merge ÷ DoG peak in the original, median per cell; rows go top to bottom):

```
shipped (stored) homographies        fixed homographies              star-centroid truth
0.09 0.27 0.59 0.77 0.79 0.56        0.86 0.84 0.85 0.89 0.91 0.90    0.87 0.83 0.85 0.89 0.91 0.91
0.37 0.20 0.10 0.15 0.29 0.58        0.82 0.69 0.73 0.85 0.90 0.89    0.84 0.72 0.75 0.86 0.91 0.91
0.04 0.02 0.02 0.01 0.03 0.05        0.79 0.64 0.76 0.78 0.86 0.88    0.83 0.69 0.79 0.80 0.86 0.89
0.02 0.01 0.00 0.00 0.01 0.01        0.84 0.70 0.74 0.78 0.82 0.90    0.87 0.78 0.82 0.80 0.85 0.91
overall 0.27                         overall 0.86                     overall 0.87
```

The shipped pattern matches the delivered frame exactly: stars survive in the top-right
cells and are gone everywhere else.

## Root cause

### 1. The horizon step

`ia_find_features` (sky branch) erodes the sky mask by `alignmentSkyHorizonExtension`
(40px), then `toGray8UWithMask` copies the frame through that mask, with zero everywhere
outside it. The comment on the erosion says it moves the step "up into sky that the
terrain cannot reach". It does move the step, but **the mask creates the step**, so the
step stays ground-locked wherever it sits. Moving it up only hides the real terrain
silhouette behind an artificial copy of it.

Moonlight makes this dominant:

| | frames 0–600 (moon up) | frames 600–1800 (dark) | frames 1860+ (dawn) |
|---|---|---|---|
| sky keypoints within 100px of the ground | 15–35% | **< 1%** | 22–93% |
| frames condemned by validation (shipped) | ~95 per 100 | 0–2 per 100 | 60, 29 |
| reciprocity score p50 | 2.8–3.7px | 0.15–0.28px | 2.6–36px |

On frame 69, 293 of 1050 keypoints sit on the step. They match very easily, because the
step has the same shape from frame to frame, so they make up 65–101 of the 137–185 Lowe
matches per pair and 9–47 of the RANSAC inliers. In a moving sequence the ground and the
sky move differently, so RANSAC has two competing motions to choose from at a 10px
tolerance. The fit it returns pins the top-right star cluster plus the horizon band and is
wrong almost everywhere else.

The star mask does not help either. `makeStarMask` thresholds the percentile-stretched
gray at 100/255. On frame 69 the sky background has a median of 109/255, so **54% of sky
pixels pass and the dilated mask covers 89.7% of the sky**. Under moonlight it selects
bright sky, not stars.

### 2. RANSAC tolerance

With step keypoints removed, frame 69 has 20–62 inliers per pair. At 10px, offsets −3, −1
and +1 were still wrong (15.3, 2.6 and 3.8px median); at 3px all eight are 0.10–0.38px.
In the dark middle of the night (300+ inliers) the tolerance is harmless. Only a thin
consensus exposes it.

### 3. Why the repair could not help

`validateMovingStarAlignment` flagged 621 frames and repaired 606 of them from "nearest
good" donors. In frames 100–600, about 5 frames in 100 passed, and they passed by chance:
their measurements carry the same step bias. Star-truth errors at three spot frames:

| frame | shipped measured, median per offset | stored after repair | **fix** |
|---|---|---|---|
| 69  | 1.46 – 7.47px | 1.38 – 6.48px | **0.10 – 0.38px** |
| 150 | 1.18 – 5.69px | 1.18 – 4.72px | **0.04 – 0.15px** |
| 300 | 0.11 – 3.63px | 0.15 – 3.46px | **0.04 – 0.08px** |
| 450 | 0.04 – 2.59px | 0.09 – 2.37px | **0.04 – 0.11px** |

Interpolating between donors cannot beat its donors, and when nearly every frame in a
stretch is biased the same way, no donor scheme can.

### Why only this camera

- **The static cameras** (a7riiia-2, a7sii-astro-2, fx3-1) replace each frame's own fit
  with one model set for the whole sequence. The dark part of the night dominates that
  model, so per-frame bias never reaches the merge.
- **The other moving camera** (a7iv-1) has its horizon lower in the frame. It had only
  0–7% step keypoints in its moonlit stretch, against 15–35% here. It is not clean,
  though: its moonlit frames have few keypoints (500–1200 of a 2000 cap), and its three
  runs repaired 215–313 frames. It would benefit from the same fixes.

### Ruled out

- **Lens distortion and model inadequacy.** One homography fits 4000–4600 star centroids
  at 0.27–0.48px RMS on every pair tested.
- **The GPU SIFT port** (`useGPUForSIFT`, on by default). CPU `cv::SIFT` on identical
  preprocessing fails the same way (1.6–9.3px), and both get similar star inliers once the
  step is removed. See the follow-up below about keypoint counts.
- **Clouds, as a source of bad keypoints.** Removing only the horizon band and tightening
  RANSAC brings every tested moonlit frame to ≤ 0.4px, so whatever keypoints the cirrus
  attracts did not decide any fit. The cirrus does matter for the merge in a different
  way; see the cloud-duplication finding on fx3-1.

## Proposal

**Status (2026-10-22): steps 1 and 2 are implemented**, together with the keypoint cache
invalidation they need (`detectionAlgorithmVersion` 2 → 3). On a cli run over the first
199 frames of this sequence, star alignment validation repaired 58 frames where the
shipped code repaired 173. The 58 are the twilight frames 0–57, which step 3 is for. On
two static sequences from the same night, the 3px tolerance kept the same inliers and
made the fits slightly more consistent (median reciprocity 0.39 → 0.16px on a7riiia-2,
0.15 → 0.12px on fx3-1). Steps 3 and 4 are still open.

### Step 1 — keep sky keypoints off the mask edge *(small; measured)*

In `ia_find_features`'s sky branch, intersect the detection mask with
`dist > skyHorizonExtension + margin`. The measured version used a 60px margin, which
means keypoints must be more than 100px from the ground. The distance transform is already
computed for the erosion.

- It has to go into the mask, not into a filter applied after detection, so SIFT's
  2000-keypoint budget is not spent on the step.
- The margin needs to cover the descriptor window (about 10σ of the keypoint scale).
  60px at full resolution covers the star-sized keypoints seen here.
- It changes cached sky keypoints, so the keypoint artifact inputs must invalidate them.

Measured on the cached keypoints (the post-detection filter, which is equivalent here
because frame 69 was under the cap): frame 69 goes from 1.5–7.5px to 0.1–15px. Most
offsets are fixed; three need step 2.

### Step 2 — sky RANSAC at 3px *(one line; measured)*

`estimateAlignment` uses `findHomography(..., RANSAC, 10, ...)` for the sky. Use 3px.
Frame 69 goes to 0.10–0.38px. Each component across the whole sequence, re-running the
shipped validation (`classifyStarHomography`, emulated exactly) on the recomputed fits:

| | frames condemned | in moonlit 100–600 | reciprocity p50, moonlit / dark |
|---|---|---|---|
| shipped | 621 | 422 | 3.04 / 0.21px |
| RANSAC 3px only | 291 | 114 | 0.38 / 0.13px |
| horizon exclusion only | 177 | 39 | 0.59 / 0.21px |
| **both** | **102** | **2** | **0.23 / 0.13px** |

**Do not ship step 2 without step 1.** RANSAC 3px alone *looks* better than it is.
Against star truth, frame 300 under 3px alone passes validation (reciprocity 0.28px) while
its −2 offset is 3.1px wrong (p90 8.3px), and frames 150 and 450 keep offsets 3.0px and
0.8px off. A fit that consistently tracks the ground is just as reciprocal as a correct
one, because both frames of the pair see the same step. With the exclusion added, those
three frames are 0.04–0.15px on every offset.

Before shipping, rerun the same recompute-and-classify on at least one wide-angle static
sequence and the 2103-frame aurora sequence. Where a homography cannot hold every star
within 3px, the consensus would shrink. Nothing here suggests it will, but it has not been
checked. `cv::USAC_MAGSAC` is the alternative if a fixed tolerance proves fragile.

### Step 3 — star-centroid refinement *(medium; prototyped)*

SIFT is a poor star matcher: stars have near-identical descriptors, so of ~750 genuine sky
keypoints on frame 69 only 20–60 survive Lowe's ratio test and RANSAC. Star stacking
software instead matches star *positions*. Add a refinement after each sky pair's RANSAC
fit:

1. **Detect** once per frame and cache next to the keypoints: DoG (σ1.2 − σ4) on
   full-resolution gray, peaks above 6σ (MAD), sky eroded 30px, 5×5 weighted centroid,
   brightest 5000. Two Gaussian blurs on one channel cost well under a second, versus
   about 29 core-seconds for SIFT at 42MP.
2. **Vote** in a 6×4 grid of cells. Predict each neighbour star with the SIFT homography
   H₀, gather offsets to base stars within 25px, and take the mode per cell (0.5px bins).
   Keep pairs within 1px of their cell's mode, fit a homography by DLT, then do 4 rounds of
   unique-nearest association within 1.5px plus a refit.
3. **Accept** if pairs ≥ N (a few hundred) and RMS < ~0.6px, otherwise keep H₀. Pair count
   and RMS also become the quality signal: a much more direct test than
   `partitionWarps`' slope band, and it works on single pairs, where reciprocity needs
   partners.

Prototype results:

- Validated on clean frame 1000: it agrees with the shipped fits to 0.03–0.08px.
- Frame 69: 4078–4301 pairs per offset at 0.27px RMS, recovering from SIFT seeds that
  were up to 19px off.
- Twilight frame 30 (fixed SIFT: 7–10 inliers; the shipped run marks it for repair):
  about 4000 pairs at 0.36px. It converges to the same matrix from an identity seed and
  from a donor seed (agreement 0.00–0.02px).

Even dawn frame 1920 has about 3600 star detections, 99% of the brightest 2000 persistent
frame to frame. So this one step covers the twilight frames that steps 1–2 leave behind.

### Step 4 — repair by guided measurement, not substitution *(small once step 3 exists)*

To answer the question directly: yes, estimate rather than replace. The estimate should
be a **measurement seeded by a prediction**, not the prediction itself.

- **Predict.** Interpolate the nearest good frames per offset in the Lie algebra
  (`HomographyLie` already exists), weighted by frame distance. That beats today's
  element-wise matrix blend, and with one donor (the start or end of a sequence) it
  extrapolates the trend instead of flat-copying it. The flat copy is what frames 0–53 got
  here.
- **Measure from the prediction** with step 3. On frame 30, frame 66's set as a seed was
  off by 1.1–10px median (16px max), and the guided measurement landed on the truth. The
  shipped run actually stored a set 3.5–15px off (32px max) for that frame.
- **Fall back** to the prediction only when the guided measurement finds too few stars
  (thick cloud).

### Follow-ups, separate from this fix

- **Star mask under moonlight.** Threshold a background-subtracted image (the same DoG as
  step 3) instead of absolute brightness, so the mask selects stars in the bright lower
  sky. This is not needed for the numbers above; it would raise the star keypoint count
  for SIFT.
- **GPU SIFT port keypoint deficit — fixed in this worktree.** On real moonlit frames the
  port returned about 58% of `cv::SIFT`'s keypoints (1050 vs 1792 on frame 69). The ported
  algorithm was faithful: with a CPU-built pyramid it returns 1791. The cause was
  `MPSImageGaussianBlur`, which behaves like a Gaussian convolved with a one-pixel box
  (variance +1/12 per pass) and pads with zeros. That shifted stars' scale-space extrema
  between layers. The pyramid now uses custom kernels with OpenCV's exact coefficients and
  reflect-101 borders. It matches the CPU reference to 1.5e-4 and returns 1792 keypoints,
  every one within 0.005px of a reference keypoint. End-to-end time is unchanged (~5.9s on
  this frame). The GPU AKAZE port (earth) had the same MPS blurs plus a clamped Scharr and
  an octave halving that drifts on odd heights. It kept 79–88% of `cv::AKAZE`'s keypoints
  on real ground and now keeps all of them. That had not measurably hurt ground alignment
  (worst-third error vs phase correlation: 2.63px before, 2.58px after, over 16 pairs).
- **Clouds in the merge.** Once these frames align, the cirrus in frames 0–600 may show the
  per-pixel banding found on fx3-1 the same day (`cloud-duplication-merge`). That is a
  separate defect in the merge kernel.

## Expected outcome on this sequence

| | shipped | steps 1+2 | + steps 3+4 (prototype) |
|---|---|---|---|
| frames condemned by validation | 621 | 102 (all twilight) | twilight measured, not substituted |
| frame 69 median error vs truth | 1.5–7.5px | 0.10–0.38px | ~0 by construction (0.27px RMS fit) |
| frame 69 star amplitude kept in merge | 0.27 | 0.86 | 0.87 |
| moonlit stretch (100–600) repairs | 422 | 2 | — |

## Reproducing

Throwaway tools in this session's scratchpad, built against the vendored OpenCV as in
`star-homography-recompute-harness`:

- `skyfit` / `skyfit3`: recompute the shipped sky fit from `keypoints/<f>.sky.div1.50.yaml`,
  optionally dropping keypoints within N px of the ground and changing the RANSAC
  tolerance. It reproduces all 1323 kept frames' stored matrices exactly.
- `skydetect`: reproduces the sky preprocessing (percentile stretch, erosion, star mask)
  with CPU `cv::SIFT` and draws keypoints over the frame.
- `starx` + `truth.py`: the star-centroid truth (step 3's algorithm, in Python).
- `classify.py`: an exact emulation of `classifyStarHomography`. It gives 621 condemned
  frames on the shipped measurements, matching the run log.
- `mergesim`: a full-resolution grayscale replica of the merge kernel, measuring per-star
  amplitude kept.

Masks: `mergedHorizon/` for every frame except the 12 painted references, which live in
`horizonReference/`.
