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

## BUG-001: `selective` is not deterministic: large stretches of sky are removed in different frames on every run

Found 2026-10-15 while checking Brian's labels with `removal_tools/` (the "nothing else changed" check), then re-measured on CI.
It started as "frame 90 is damaged"; repeating the run showed that frame 90 was not special.

### What was observed

`star -c selective` on `a7sii_10_crop16` (the first 19 frames of the `a7sii_10` sequence, Sony a7S II, cropped to x=1500 y=600
w=2300 h=1450, 16-bit LZW TIFF, see `test_data/datasets.json`). In selective mode every pixel outside the removal masks must be
bit-identical to the input (lossless input), so `star-removal-verify --unchanged-outside` counts pixels Star changed outside any
labelled trail. Result per run (total changed px outside labels; hand labels are the 122 objects in `a7sii_10_crop16/labels.json`):

| run | total px | where the bulk is |
|---|---|---|
| iMac Pro, Vega GPU path, first run | 44,022 | frame 90: 28,655 |
| iMac Pro, Vega GPU path, **same machine, same files, same binary, second run** | 80,826 | frame 97: 64,135 (frame 90 is now 903) |
| macos-15 CI, GPU path (Apple Paravirtual) | 45,771 | frame 86: 21,434, frame 92: 13,344 |
| macos-15 CI, CPU path (`--no-use-gpu*`) | 14,419 | frame 92: 6,247 |
| ubuntu-24.04 CI, CPU | 62,543 | frame 97: 31,579, frame 96: 13,233, frame 90: 7,035 |

Across the two local runs only 4 of the 11 affected frames had identical areas, and 3 objects' removed-or-not verdict also
changed (`00082-13`, `00097-4`, `00097-5`).

### Measured

* The big changed regions are not scattered. In the first local run frame 90's components lie on one straight line,
  y = 0.0987·x + 469.8 (crop coordinates), residual 1.9 px, x≈934 to 2265, holding 97% of the 28,655 px. On CI frames 86 and 92
  (GPU path) the large components also lie on straight lines (residuals 2.7 and 5.3 px over about 1,000 px).
* Peak per-pixel change inside them is 0.3 to 0.5 of full scale, and in the output the Milky Way stars along the line are
  replaced by faint diagonal smears (compare the input and output of frame 90 high-passed with a 0x12 blur).
* In the input, no trail is visible by eye along those lines (Brian looked; the high-passed 89/90/91 do not show one).

### What it means (hypotheses, not yet separated)

1. Star detects very faint straight linear features in dense star fields (real faint airplanes/satellites, or a
   linear artifact such as sensor banding or a long satellite flare) and removes them, but whether a given one is detected
   differs run to run, so the unlabelled changes land in different frames. Then the "labels are incomplete" part is real
   but cannot be fixed by labelling, because the set of detections moves.
2. The detection or its classification involves non-determinism. The project memory note `star-test-suite-findings` records
   that `BunchCalculator` has non-determinism (and that polarCoords mirroring and `ImageMatrixElement.contains` changed decision
   tree features), which is a lead, not a confirmed cause.
3. Independently of 1 and 2, the repaint of a removed faint line in a dense star field looks bad (smeared streaks). This
   is a removal-quality defect.

Do not "fix" it by loosening the check or by changing what `selective` is supposed to do.

### How to reproduce

```bash
test_data/fetch.sh a7sii_10_crop16
mkdir /tmp/c16 && cp -R .test-data/a7sii_10_crop16/*.tif /tmp/c16/        # a fresh copy each run: Star derives paths from the dir name
cli/.build/release/star -l info -c selective -o /tmp/c16-out /tmp/c16     # about 25-35 min, see BUG-003
cd removal_tools && swift build -c release --product star-removal-verify
.build/release/star-removal-verify --input ../.test-data/a7sii_10_crop16 --output /tmp/c16-out/<the *star-v-* dir> \
    --labels ../.test-data/a7sii_10_crop16/labels.json --unchanged-outside --clean-method selective \
    --report /tmp/rep.json --crops /tmp/crops --report-only
# repeat with a second fresh copy and compare the per-frame "collateral" areas in the two reports
```
`gherkin/measure-removal.sh macos <out>` with `MEASURE_FILTER=a7sii_10_crop16-selective` does the same thing.

### Where to look

* `StarCore/Sources/StarCore/FrameAirplaneRemover.swift` (selective branch, `computeRemovalMask`); outlier-group detection and
  `BunchCalculator`; a run with `-w --keep-temp-files` to see which group was decided remove (`OutlierGroupPaintData.json`).
* **Control measured:** the full-frame 16-bit conversion of the same frames (`a7sii_10_16bit`), `selective`, on the iMac Pro, run twice:
  all 19 frames identical between the two runs, 6,723 changed px in total (39 to 1,073 per frame, 4 frames at 0). So the
  non-determinism is specific to the cropped frames (no ground, dense Milky Way only), not to lossless 16-bit input or to `selective` in general.
* The CI artifacts of the 2026-10-15 runs (`removal-measurements-{linux,macos}`, workflow run ids 38801175389 and 38798344452).

### Referenced from

* `gherkin/removal-thresholds.json`, `unchanged_outside_max_area` (left unset because of this bug).

### Status

Open. Not a regression test yet. Owner: unassigned. The crop is the trigger; the full-frame 16-bit control is reproducible. No same-platform repeat has been done for the full-frame JPEG dataset or on CI.

---

## BUG-002: cropped, sky-only 16-bit frames lose 30 to 70% of their star flux in `automatic:false` and `automatic:true`

Found 2026-10-15 in the CI measurement run (identical on macOS and Linux).

### What was observed

`a7sii_10_crop16` (see BUG-001 for what it is), `-c automatic:false`: the star check (peaks over 10σ in the input, flux compared with the output
at the same pixel) gives a per-frame median ratio of **0.282 to 0.738** (overall 0.585, ubuntu and macos alike) and 47 to 52%
of the peaks below half their input flux. `automatic:true` gives 0.80 to 0.95 and 44 to 45% lost. The same frames at full
size (`a7sii_10`, `automatic:false`) give 0.933 to 0.993 and 1.4% lost; the full-frame 16-bit conversion run locally gives about 0.97.
`selective` on the crop gives exactly 1.000 (it does not touch those pixels).

### Measured

* ~8,600 to 9,600 peaks per frame in the crop, p5 of the ratio is about -0.03 (some stars come back as nothing), p95 about 1.14.
* The ratio is not uniform: frames 88 to 91 are worst (0.28 to 0.37).

### What it means (hypotheses, not yet separated)

Not investigated. Candidates: the crop has no ground, so horizon detection/earth alignment takes a different path; the star-aligned
median of neighbours is mis-aligned by a fraction of a pixel in a very dense star field, which dims every star at its original
position; or the aligned frames are displaced. The verifier's star check compares at fixed pixel positions, so a uniform
sub-pixel shift would show up exactly like this.

### How to reproduce

As BUG-001 but with `-c automatic:false` (about 40 s), then run `star-removal-verify ... --stars` and read `stars` in the report.

### Where to look

Star's alignment for sequences with no horizon (`--no-horizon` and the no-ground path), `homography.db` replay (project
memory `merge-replay-verification`), and a visual flicker of input vs output stars.

### Referenced from

* `gherkin/removal-thresholds.json` `stars_*` notes (they are only valid for `a7sii_10`, not the crop).

### Status

Open. Until understood, do not use the crop set for a "stars are preserved" expectation.

---

## BUG-003: `selective` and `automatic:true` take 25 to 35 minutes on the cropped 16-bit set, against about 2 to 4 minutes at full size

Found 2026-10-15 in the CI measurement run.

### What was observed

| run | a7sii_10 (4240x2832 JPEG) | a7sii_10_crop16 (2300x1450 16-bit TIFF) |
|---|---|---|
| macos-15 selective | 135 s | 1,471 s |
| macos-15 automatic:true | 123 s | 1,517 s |
| macos-15 automatic:false | 79 s | 39 s |
| ubuntu-24.04 selective | 205 s | 2,090 s |
| ubuntu-24.04 automatic:true | 207 s | 2,077 s |
| ubuntu-24.04 automatic:false | 116 s | 47 s |

`automatic:false` (no outlier groups) is fast on the crop, so the slow part is the outlier-group stage (detection or classification). The
crop frames are smaller but denser in stars (the Milky Way) and are 16-bit. It also took 30 minutes on the iMac Pro locally, so it is not a runner artifact.

### What it means (hypotheses, not yet separated)

Not investigated: a very large number of outlier candidates in a dense field is the obvious suspect; 16-bit versus 8-bit input is another.

### How to reproduce

`MEASURE_FILTER=a7sii_10_crop16-selective gherkin/measure-removal.sh macos <out>` and read `star.status` and `star.log`.

### Where to look

A sample of the running `star` (project memory `main-thread-stall-diagnosis` describes sampling), and `star.log` with `-l verbose`.

### Referenced from

None yet. It makes the crop set unattractive as a CI fixture (a feature on it would take 35 minutes per leg).

### Status

Open.

---

## BUG-004: per-object removal verdicts differ between platforms and runs while the totals stay put

Found 2026-10-15 comparing the macos-15 (GPU) and ubuntu-24.04 (CPU) CI runs on the full-frame `a7sii_10` JPEG set.

### What was observed

Same 226 measurable labelled objects, same source. Counting an object removed when its median stretch ratio is below 0.5:
* `automatic:false`: 226 removed on both, no object differs.
* `automatic:true`: 188 (macos) vs 189 (linux) removed, **7 individual objects differ** (`00084-12`, `00085-15`, `00086-14`,
  `00088-12`, `00092-6`, `00094-7`, `00096-5`).
* `selective`: 47 removed on both, **2 objects differ** (`00084-12`, `00092-6`).

### What it means (hypotheses, not yet separated)

The classifier's remove/keep decision depends on the platform (GPU versus CPU keypoints and alignment feed it) or is itself not
deterministic (see BUG-001). Whether the differences are platform or run-to-run was not measured for this dataset: only one run per platform.
This is why the real-data `automatic:true` check judges the fraction removed (`removed_fraction_min`) and not each object.

### How to reproduce

Run the measurement workflow (`.github/workflows/removal-measure.yml`) and compare the `report.json` objects between the two artifacts; or run the same
`a7sii_10` configuration twice on one machine and diff.

### Where to look

`OutlierGroupPaintData.json` under `-w --keep-temp-files` on each platform for one of the objects above; `FrameAirplaneRemover.swift` classification path.

### Referenced from

* `gherkin/removal-thresholds.json` `removed_fraction_min`.

### Status

Open. Needs a same-platform repeat to separate platform from run-to-run non-determinism.

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
