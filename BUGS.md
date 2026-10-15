# Known bugs

A short list of real, reproduced problems that are not fixed yet, written so an agent who has never seen the
conversation can pick one up.

## How to use this file

* **Add** a bug: copy the template at the bottom, give it the next `BUG-nnn` number (numbers are never reused),
  and fill in every heading. Say what is **measured** and what is only **suspected**; keep them apart.
* **Delete** a bug when it is fixed: remove its whole section, in the same commit as the fix. Git history keeps it.
  If a bug is referenced from a baseline (see "Referenced from"), remove that reference in the same commit. The
  verifier will fail the run until you do, which is deliberate.
* Do not use this file for ideas or wishes. Only things that were reproduced.

---

## BUG-001: `selective` repaints a faint 1300 px trail through the Milky Way and leaves smeared streaks (and the trail is not in the labels)

Found 2026-10-15 while checking Brian's labels with the new removal verifier (`removal_tools/`).

### What was observed

Dataset `a7sii_10_crop16` (the first 19 frames of the `a7sii_10` sequence, Sony a7S II, cropped to x=1500 y=600
w=2300 h=1450 and stored as 16-bit LZW TIFF; see `test_data/datasets.json`). Run with the release cli,
`-c selective`, on a fresh copy of the 19 frames. Frame `LRT_00090.tif` is the interesting one.

`star-removal-verify ... --unchanged-outside --clean-method selective` compares output with input in selective mode,
where every pixel outside the removal masks must be bit-identical (lossless input). In frame 90 it found
**28,655 changed pixels in 56 connected components outside every labelled trail**. The other 18 frames total only
about 15,400 changed pixels between them (the next largest frames are 86 at 5,561 and 89 at 4,576).

### Measured (all in crop coordinates)

* The changed components are not scattered. The 10 components over 1,000 px each have their centres on one straight
  line: **y = 0.0987·x + 469.8, maximum residual 1.9 px, running from x≈934 to x≈2265** (about 1,340 px long).
  15 of the 56 components lie within 25 px of that line and hold **27,752 of the 28,655 changed pixels (97%)**.
* In full-frame coordinates (the JPEG frames, 4240×2832) that line is y = 0.0987·x + 921.8, from about (2434,1162) to
  (3765,1293).
* Peak per-pixel change in the components is 0.3 to 0.5 of full scale, so the pixels were really altered, not
  rounding noise.
* Looking at the output (not just the report): along that line the stars are replaced by faint diagonal smears
  ("painted" streaks). The picture is `.test-data/review/frame90_band.png` in the worktree it was made in (it is
  git-ignored; regenerate it with ImageMagick from the input and output frames, high-passed with a 0x12 blur).
* In the **input** frames (89, 90, 91, high-passed) no trail is visible to the eye along that line. The straightness
  of the changed pixels is the evidence that something linear was there and that Star's classifier decided to remove it.

### What it means (hypotheses, not yet separated)

1. **There is a real, very faint, unlabelled trail** (airplane or satellite) in frame 90 along that line, which Star
   detected and removed. Then the label set is incomplete for frame 90 (Brian labelled all frames by eye and could not
   see it), and the "nothing else changed" check is correctly pointing at a missed label. Fix: add it to the labels.
2. **Whatever Star removed there, the repaint is visibly bad**: the Milky Way star field comes back with smeared
   streaks along the trail. That is a removal-quality defect in dense star fields even if (1) is true. This is the
   part that is a Star bug. Not investigated: whether the smear comes from the star-aligned median of neighbour frames
   being misaligned in that region, from the soft 8 px `RemoveMask` falloff blending, or from the paint step
   (`computeRemovalMask` and the `selective` branch in `StarCore/Sources/StarCore/FrameAirplaneRemover.swift`).

Both can be true at once. Do not "fix" it by loosening the check or by changing what `selective` is supposed to do.

### How to reproduce

```bash
# 1. get the dataset (needs the test-data release assets uploaded)
test_data/fetch.sh a7sii_10_crop16
# 2. process a fresh copy (Star derives its paths from the input dir name, so never reuse a directory)
mkdir /tmp/c16 && cp -R .test-data/a7sii_10_crop16/*.tif /tmp/c16/
cli/.build/release/star -c selective -o /tmp/c16-out /tmp/c16
# 3. check it
cd removal_tools && swift build -c release --product star-removal-verify
.build/release/star-removal-verify --input .test-data/a7sii_10_crop16 --output /tmp/c16-out/<the star-v-… dir> \
    --labels .test-data/a7sii_10_crop16/labels.json --unchanged-outside --clean-method selective \
    --report /tmp/rep.json --crops /tmp/crops --report-only
# frame LRT_00090.tif: ~28.6k changed pixels; look at crops/LRT_00090_changed0.png and the report's "collateral"
```

Expected after a fix: the area in frame 90 within the verifier's `unchanged_outside_max_area` limit (once Phase 4
has measured one), either because the trail is now labelled or because Star no longer damages the sky there.
Note: one full crop run took 30 minutes of wall clock when the machine was heavily loaded; it normally takes about
1.5 minutes at full frame size.

### Where to look

* The verifier output for this frame; `removal_tools/Sources/RemovalCore/Collateral.swift` (the component finder).
* Star: `StarCore/Sources/StarCore/FrameAirplaneRemover.swift` (selective branch, `computeRemovalMask`), and a run with
  `-w --keep-temp-files` to see which outlier group was decided remove in frame 90 (`OutlierGroupPaintData.json`,
  `star_temp_*`).
* Labels: `test_data/labels/a7sii_10.labels.json` (full frame) and `test_data/labels/a7sii_10_crop16.labels.json`.

### Referenced from

* `gherkin/removal-baseline.json`, `collateral` entry for `a7sii_10_crop16` / `LRT_00090.tif` / `selective`
  (area 28,655). Its area is reported but left out of the unchanged-outside total. When this bug is fixed or the trail is
  labelled, the verifier fails with "remove it from removal-baseline.json": remove the entry then.

### Status

Open. Not a regression test yet (no Gherkin feature runs these checks; thresholds are unmeasured). Owner: unassigned.

---

## Template

```markdown
## BUG-nnn: <one line: what is wrong, where>

Found <date> while <doing what>.

### What was observed
<the symptom, with the exact dataset / command / frame>

### Measured
<numbers, with units and coordinate frame. Only things you actually measured.>

### What it means (hypotheses, not yet separated)
<what you think is going on, and what you have not ruled out>

### How to reproduce
<commands a fresh agent can copy>

### Where to look
<files, functions, logs>

### Referenced from
<baseline entries, tests or docs that mention this bug, so they can be removed with it>

### Status
<Open / in progress / owner>
```
