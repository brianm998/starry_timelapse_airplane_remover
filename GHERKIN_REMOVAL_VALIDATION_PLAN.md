# Gherkin: checking airplane and satellite removal in the output images

Instructions for the agent who builds this. Today the Gherkin features only count output files.
This work makes them check that airplanes and satellites are actually gone from the output, and
that nothing else was damaged.

**Read first:**
- `gherkin/README.md`
- `GHERKIN_SPEED_AND_TEST_DATA_PLAN.md`. This plan builds on its dataset manifest, `fetch.sh`
  and `data:` placeholders.
- Project memory `removal-validation-oracle`, which has the measurements below in more detail.

**Prerequisite:** the speed/test-data work (branch `claude/gherkin-speed-test-data-8b2cf1`) must
be merged to `develop` first. If it isn't, phases 1 and 2 can start, since they need no
manifest. Phase 4 can't.

---

## What is already known (measured 2026-10-14; don't re-litigate)

Measured with a release cli on `test_data/test_a7sii_10`, converted to 16-bit TIFF with
`magick in.jpg -depth 16 -compress lzw out.tif`. Frame `LRT_00092` has a red, strobing airplane
trail, roughly `y = 0.2215·x + 190.8` for x 548..999.

**1. Golden images and whole-frame similarity can't be the check.**
- The default mode, `.automatic(false)`, writes a star-aligned, sigma-clipped median of the frame
  and up to 8 neighbours. Every pixel is recomputed, so no output pixel equals the input.
- macOS defaults to Metal for SIFT, AKAZE and the merge; Linux and Windows always use the CPU.
  They find different keypoints, so the homographies and output pixels differ by platform.
- JPEG input is re-encoded on output.
- A trail is about 0.1% of the frame, so PSNR or SSIM over the whole image barely sees it.

**2. Trail contrast along a labelled line works, with a wide margin.**
- Brightness: the mean of the three channels.
- **On-line:** the median over pixels within 4 px of the line.
- **Background:** the median over two side bands, 12–30 px from the line.
- **Contrast** = on-line − background. Compute it per 50 px stretch of the line, as a ratio to the
  same stretch in the input.
- **Results on frame 92:**
  - input: 1.00
  - `automatic`: −0.009 (worst stretch 0.040)
  - old buggy `automatic:true`: 1.03
  - fixed `automatic:true`: 0.006 (worst stretch 0.130). That stretch is a fragment the classifier
    called keep, which is restored by design.
- The prototype lived in a session scratchpad and is gone. Re-implement it from this
  description.

**3. Stars can only be checked as a distribution.**
- Default `automatic` vs input, over 31,810 peaks: aperture-flux ratio median 0.961, p5 0.667,
  p95 1.278, and 1.9% of peaks below 0.5.
- Any per-star rule would fail all the time.
- Peak finding that worked: subtract a 32 px block-median background, take the MAD sigma, keep
  local maxima above 10σ in a 7×7 window. Flux = the 7×7 sum minus 49 × the median of the
  17×17 box around it.

**4. Labels must be drawn independently of Star.**
- `OutlierGroupPaintData.json` mixes classifier and user decisions.
- It leaves out trash groups, so the training pipeline counts them as negatives.
- It can be rewritten as `.userSelected` from validation images nobody looked at.
- It only covers groups Star found, so a trail Star missed can't be labelled.
- It is not ground truth, and must not be used as the oracle.

**5. Facts about the pipeline the checks depend on.**
- Paths are in `StarCore/Sources/StarCore/FrameAirplaneRemover.swift`.
- **`.selective`:** the output is the original frame. Only pixels within the soft 8 px
  `RemoveMask` around groups decided remove change: full strength within 2 px, fading to 0 at
  8 px (`computeRemovalMask`). They are replaced from the star-aligned median, or the earth image
  below the horizon.
  - With lossless 16-bit input, every other pixel is **bit-identical** to the input.
  - With 8-bit input, they are also exact (×256, then ÷256).
- **`.automatic(false)`:** the whole frame is the median composite. There is no outlier data at
  all.
- **`.automatic(true)`:** the auto composite, with original pixels restored over groups decided
  **keep**. That was fixed in `1b2cb327` (it used to restore the remove groups and crash on 8-bit
  input), and `AutoPreservationRestoreTests` pins it.
- The classifier is **binary** (remove/keep). There is no airplane/satellite/meteor class in the
  code.
- **cli flags:**
  - `-c selective|automatic:true|automatic:false`
  - `-w` saves `OutlierGroupPaintData.json`, `paintMask` previews and `aligned-subtracted`
  - `--keep-temp-files` keeps the temp dir, which is otherwise deleted after a successful run
  - The temp dir is `<outputPath>/star_temp_<seq>`, next to the input when `-o` isn't given.
- **Loaders** (public StarCore): `Config.read(fromJsonFilename:)`,
  `OutlierGroups(at:fromOutlierDir:config:)` (needs `config.imageWidth`/`imageHeight` set), and
  `BlobBinaryLoader`.

---

## Design

### Labels: `labels.json`, shipped inside each dataset archive

```json
{
  "version": 1,
  "frames": {
    "LRT_00092.jpg": [
      { "id": "a92-1", "class": "airplane", "points": [[548, 312], [999, 412]], "width": 8,
        "confirmed": true, "note": "red strobe, two parallel wingtip lines" }
    ]
  },
  "sky": [[0, 0], [4240, 0], [4240, 1900], [0, 2100]],
  "complete": true
}
```

- **`class`:** one of `airplane`, `satellite`, `meteor` or `other`.
- **`points`:** a polyline in full-resolution input pixel coordinates.
- **`width`:** the trail's full width in pixels.
- **`confirmed`:** only `true` objects are checked. Drafts stay `false`.
- **`sky`:** an optional polygon. Star peaks and collateral checks only look inside it, which
  keeps ground lights and the horizon out.
- **`complete`:** `true` means every trail in every frame is labelled. Only complete label sets
  may be used for the "nothing else changed" check.

### The verifier: one tool, called by every client's runner

A standalone SwiftPM package `removal_tools/`, following the repo's standalone-tool pattern
(swift-tools-version 6.0, ArgumentParser + StarCore, `static let configuration`). It uses
StarCore's `PixelatedImage` loading, so it decodes files exactly as Star does. It has two
executables: `star-removal-verify` (this section) and `star-trail-inject` (Phase 3).

```
star-removal-verify --input <dir> --output <dir> --labels <labels.json>
                    --expect "airplane=removed,satellite=removed" [--stars] [--unchanged-outside]
                    [--base-output <dir>]            # differential mode, synthetic datasets
                    [--temp <star_temp dir>]         # optional decision diagnostics
                    --thresholds gherkin/removal-thresholds.json
                    --report <report.json> --crops <dir>
```

**Matching frames.** Match output frames to input frames by base name. Star keeps the input's
name and extension.

**Trail check.** Applies to every confirmed object whose class is in `--expect`. Use the
contrast measure above:
- **Bands:** the on-line band is `width/2`; the background bands run from `width/2 + 8` to
  `width/2 + 26`.
- **Faint stretches:** a stretch is unmeasurable if its input contrast is below 5σ of its own
  background. Skip it and count it. If more than 20% of an object's length is unmeasurable, the
  label is bad, and the verifier must fail it as a label error rather than pass or fail the
  removal.
- **Pass rule:** `removed` passes when every measurable stretch's ratio is ≤ `removed_max`. `kept`
  passes when every stretch is ≥ `kept_min`.
- **Report:** per object, every stretch's ratio, the worst stretch, the fraction of the length
  removed, and the measurable fraction.

**Star check (`--stars`).** Use the distribution measure above, inside `sky`, at least 40 px from
any labelled object. It passes when the median flux ratio is within `[stars_median_min,
stars_median_max]` and the fraction below 0.5 is ≤ `stars_lost_max`. Report the counts and
percentiles.

**Unchanged outside (`--unchanged-outside`).** Only valid for `.selective` with lossless input and
a `complete` label set. The verifier must refuse anything else.
- **Footprint:** the labelled polylines, dilated by `width/2 + 10`.
- **What to report:** every connected component of pixels where output ≠ input outside the
  footprint, with its bounding box, area and peak difference, plus a crop.
- **Pass rule:** total area ≤ `unchanged_outside_max_area`.
- Each component is something Star removed that nobody labelled: either a missed label or a
  false positive. The report must make it easy to tell which.

**Differential mode (`--base-output`).** For synthetic datasets, the oracle is Star's own output
on the un-injected base, not the input.
- **Inside each injected footprint:** the contrast of output − base-output must be ≤ `removed_max`
  × the injected contrast.
- **Outside every footprint:** the fraction of pixels whose |output − base-output| > 6σ must be
  ≤ `differential_outside_max`. Injected bright pixels can shift alignment slightly; this is
  where you find out how much.

**Decision diagnostics (`--temp`).** Only when Star ran with `-w --keep-temp-files`, so cli only.
- For each failing object, load that frame's outlier groups and decisions, and say which case
  it is:
  - no group within the footprint (**not detected**)
  - groups overlapping it decided keep, with their scores (**misclassified**)
  - groups decided remove but the pixels are still bright (**painting/merge problem**)
- This is diagnosis only. It never changes pass/fail.

**Output.**
- `report.json`, with a summary block and per-object detail.
- Crops: input | output | difference, side by side, auto-levelled, one PNG per failing object
  (and per collateral component).
- Exit code 0 if everything passes, 1 on failure, 2 on bad input (bad labels, missing frames,
  wrong mode for `--unchanged-outside`).

**Thresholds** live in `gherkin/removal-thresholds.json`. Each entry has its value plus a
`measured` field: the distribution it was set from, the dataset and the date. JSON has no
comments, so the evidence lives in the data.
- **Never guess a threshold.** Set it in Phase 4 from measurements.
- Until then, the verifier runs in `--report-only` mode, which always exits 0 and prints the
  numbers.

**Tests for the verifier itself.**
- Unit tests over synthetic arrays: a flat background with a known line painted in, checked
  against known ratios.
- A star field with a known flux scale.
- A selective-style output with one unlabelled changed blob, which must be reported as one
  component with the right area.
- Run them on Linux and macOS (`swift test`).

### Known failures on real data: a ratchet, not a red build

Real data will contain trails Star misses today. `gherkin/removal-baseline.json` lists them, one
entry per (dataset, frame, object id, clean method), with the measured worst ratio and the date.
- **Known failure** (in the baseline, still failing): pass, and say so in the report.
- **Regression** (not in the baseline, failing): fail.
- **Fixed** (in the baseline, now passing): **fail**, with "remove it from
  removal-baseline.json". That keeps the baseline honest; Preffect's `gherkin-lint` ratchets the
  same way.

Synthetic datasets get **no** baseline entries. If Star misses a synthetic trail, either the
injection is unrealistic or Star has a real gap. Report it rather than baselining it.

---

## Phases

### Phase 1: the verifier, report-only

Build `removal_tools/star-removal-verify` and its unit tests, as above, with `--report-only` as
the only mode that ships in this phase.

Then validate it by hand against the frame-92 case, with labels you draw yourself just for this.
Write them in the dataset's draft file, never as `confirmed`. It must reproduce the numbers in
"What is already known" to within noise:
- `automatic` ≈ −0.01
- old `automatic:true` ≈ 1.03 (check out a commit before `1b2cb327` to get that output)
- fixed `automatic:true` ≈ 0.006

If it doesn't, find out why before going further.

### Phase 2: labelled real data (needs Brian)

**1. A labelling page:** `tools/label-trails/index.html`.
- One self-contained HTML file with no build step and no network.
- You open a frame directory through a file input, it shows frames with zoom and pan, and you
  click polyline points.
- For each object you set class and width, mark it confirmed, and add a note.
- It exports `labels.json` and can load an existing one for editing.
- It shows unconfirmed (draft) objects differently from confirmed ones.

**2. Drafts from Star's own output, clearly marked `"confirmed": false`.**
- Run the cli with `-c selective -w --keep-temp-files`.
- Fit a polyline to each remove-decided group's pixels, and merge collinear fragments across
  strobe gaps.
- Write the result to `labels.draft.json`.
- This only saves Brian clicks. Brian confirms or corrects every object, adds the ones Star
  missed (look at the remove-mask previews and at the frames themselves), and sets the class.
  **Never mark anything confirmed yourself.**

**3. First datasets:**
- **`a7sii_10`:** the existing 19 JPEG frames, which contain real airplanes (frame 92 has
  several). Labels go into the dataset archive, which means a new archive name and a manifest
  edit.
- **`a7sii_10_crop16`:** the same frames converted to 16-bit LZW TIFF and cropped to a sky region
  of at least 2000×1400 that contains the labelled trails. Use the same crop rectangle on every
  frame, and record it in the dataset description.
  - Lossless input is what makes `--unchanged-outside` possible.
  - Crop rather than downscale, so trails stay at the pixel scale the decision trees were trained
    on. Downscaling changes the blob features the classifier sees.
- Building archives, computing hashes and asking Brian to run the upload follow
  `GHERKIN_SPEED_AND_TEST_DATA_PLAN.md`, Part 2. **Brian uploads, the agent doesn't.**

**4. Stop point:** give Brian the drafts and the labelling page, and wait for confirmed labels.
Phase 3 can proceed meanwhile.

### Phase 3: synthetic trails with an exact answer key

`removal_tools/star-trail-inject`: deterministic, seeded, run once to *build* a dataset (never at
test time).
- **Input:** a base sequence (a real sky crop) and a spec file.
- **Output:** `base/` (an unchanged copy), `injected/`, and `labels.json` (`confirmed: true`,
  because the geometry is exact by construction).
- **Satellites:** a straight line with a Gaussian cross-section (FWHM 1.5–3 px) and constant
  brightness along its length. Sweep the amplitude across SNR 3, 5, 10, 30 and 100 against the
  local background sigma. Real satellites continue collinearly into the next frame with a small
  gap, so do that for some of them.
- **Airplanes:** two parallel lines 3–6 px apart, plus periodic bright strobe dots, tinted
  red/green/white per channel, at varied angles and lengths. Some cross bright stars, and some
  run off the frame edge.
- **Meteors** (measured only, never must-pass; see "Not in scope"): a single frame, short, tapered,
  with a bright head.
- Add the signal to the base in linear 16-bit, clamping at 65535. Write lossless TIFF.
- **Base sequence:** a crop of `a7sii_10_crop16` that has no labelled trail. Prove it's clean: run
  Star on it, and the verifier in `--unchanged-outside` selective mode must find nothing.

**Check that the synthetic trails are realistic** (report it, and don't skip it):
- Compare Star's detection rate on synthetic airplanes and satellites with its rate on Brian's
  labelled real ones, at similar measured contrast.
- If synthetic trails are much easier or harder to catch, adjust the generator before trusting it.

### Phase 4: measure, then set thresholds

Run every dataset × every clean method the features will use, on the cli on `ubuntu-24.04` and on
`macos-15`. Note whether Metal was actually used on the macOS runner: log the GPU path decision.
If hosted runners have no Metal, macOS CI is testing the CPU path too, and that has to be said.

Then:
- Collect each metric's distribution into a table in the PR description.
- Set each threshold in `removal-thresholds.json` with clear margin on both sides, recording the
  `measured` evidence.
- Write the known failures on real data into `removal-baseline.json`.

**If the passing and failing distributions overlap for a metric, don't pick a number.** Report
it, and change the metric (band widths, stretch length) until they separate.

### Phase 5: Gherkin steps, features and CI

**New `steps.json` entries** (exact text, as always):

| case | text |
|---|---|
| `setCleanMethod` | `the clean method is {clean_method}` |
| `processWithBase` | `I process the injected sequence and its base` |
| `airplanesRemoved` | `the labelled airplanes are removed` |
| `satellitesRemoved` | `the labelled satellites are removed` |
| `starsPreserved` | `the stars are preserved` |
| `nothingElseChanged` | `nothing outside the labelled trails changed` |

**Runner rules:**
- Every `Then` step runs `star-removal-verify` as a subprocess and fails with its summary, plus
  the path to the report and crops.
- **cli:** `setCleanMethod` maps to `-c`. The runner always adds `-w --keep-temp-files`, so it can
  pass `--temp` for diagnostics.
- **GUIs:** they only run scenarios in the default clean method, so `setCleanMethod` is cli-only.
  Don't plumb clean-method selection into the GUI runners in this work.
- **XCUITest:** check first that the UI-test runner can launch a subprocess and read the
  output directory. If it can't, run the verifier as a separate CI step after `xcodebuild test`,
  with the paths the test wrote to a known file. Keep the vacuous-green guard either way.
- **Building the verifier:** each CI leg builds `removal_tools` in release next to what it already
  builds. Windows works because StarCore already builds there for `stard`.

**First features** (one Scenario each, lowerCamelCase names):

| feature | tags | what it proves |
|---|---|---|
| `removeAirplanes` | `@cli @mac-gui @desktop` | default automatic on `data:a7sii_10`: airplanes removed, stars preserved. The only removal feature on the GUIs; it proves their settings reach the engine. |
| `selectiveRemovesOnlyTrails` | `@cli` | selective on `data:a7sii_10_crop16`: airplanes removed, nothing else changed |
| `autoPreservationKeepsAirplanesOut` | `@cli` | `automatic:true` on both datasets: airplanes removed. A regression test for `1b2cb327`, on JPEG and 16-bit. |
| `syntheticSatellites` | `@cli` | differential, the SNR sweep: satellites removed |
| `syntheticAirplanes` | `@cli` | differential: airplanes removed |

The full removal suite runs on the cli only, on Linux and macOS, which covers the CPU and GPU
paths. The GUIs share StarCore, so repeating the suite there would cost a lot of runner time
without testing different code.

**CI:**
- Upload every verifier report and crop directory as artifacts with `if: always()`. They are the
  only way to see a removal failure.
- The vacuous-green guards stay. Additionally, check that each report's object count is the
  number of labelled objects the feature expects, so a step that silently checked nothing fails.

---

## Done means

- All five features are green on every leg that runs them.
- A deliberately broken removal turns the right features red with a readable report and crops.
  Prove it once on a throwaway commit, then revert. For example, set `outlierGroupPaintBorderPixels`
  to 0, or invert the selection in `computeRemovalMask` again.
- `removal-thresholds.json` carries the measured evidence for every threshold.
- `gherkin/README.md` documents:
  - labelling (the page, the drafts, the confirmed rule)
  - the verifier's checks
  - the baseline rules
  - how to add a removal feature
- The project memory `removal-validation-oracle` is updated with the measured distributions and
  thresholds.

## Stop and ask Brian before

- marking any label confirmed (he does it)
- uploading datasets (he does it)
- adding any meteor expectation, or changing what a clean method is supposed to do
- baselining a failure in a synthetic dataset

## Not in scope

- **Must-pass meteor expectations.** The classifier is binary and can't tell meteors from
  airplanes, so "meteors are kept" would fail by design. Measure and report meteor survival on
  synthetic data only.
- Clean-method selection in the GUI runners.
- Moving or horizon-crossing sequences, clouds, aurora, ground lights.
- Retraining the decision trees.
- Datasets over 2 GiB.
- Changing Star's removal behaviour to make a test pass.
