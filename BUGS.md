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

## BUG-007: the automatic horizon detector invents a horizon on a sky-only sequence, and everything below it is treated as unaligned ground

Found 2026-10-26 chasing the crop-fixture failures that BUG-001 to BUG-003 used to describe (those entries are deleted: BUG-001's non-determinism and
BUG-003's 25 to 35 minutes were fixed by the blob-pipeline work, C3 and S14; what was left of all three was this).

### What was observed

`a7sii_10_crop16` is the first 19 frames cropped to x=1500 y=600 w=2300 h=1450: all sky, no ground (`test_data/README`, `datasets.json`). Run with star's default
horizon detection, the detector reports a horizon anyway (`CombinedHorizonDetector: done, horizon Y range [141..492]` in the 1009 px working image, with the
`dp` method at confidence 1.00). Star then treats the part of the frame below it as ground: not star-aligned, merged from neighbours that do not move. Stars do move
between frames, so the median of the unaligned frames erases them there.

### Measured (iMac Pro, release cli, current develop, the 19-frame crop)

| | default horizon detection | `--no-horizon` |
|---|---|---|
| star flux ratio, `automatic:false`, top band (crop y 0-450) | 0.94-0.98 | 0.96-1.00 |
| ... middle band (y 500-950) | **0.05-0.10** | 0.95-1.00 |
| ... bottom band (y 1000-1450) | **0.01-0.05** | 0.95-1.00 |
| `selective` wall time (`-n 3`) | 206 s and 247 s, peak 10.5 GB | **32 s and 35 s, peak 2.9 GB** |
| `selective` changed px outside the labelled trails (122 labels) | **80,939** | **2,899** |
| `selective` determinism, two runs | byte-identical on 19 of 19 frames | byte-identical on 19 of 19 frames |

Before the pipeline work the same default-horizon `selective` run took 25 to 35 minutes on CI and was not deterministic (BUG-001: 44,022 then 80,826 px on one machine),
which is why the crop was written off as a bad fixture. With `--no-horizon` it is a good one: fast, deterministic and calm.

### What it means (hypotheses, not yet separated)

The detector has no "there is no horizon" outcome: on a frame that is stars all the way down, the `dp` and `tex` methods still find an edge in the gradient of the Milky Way and
agree on it. The consequences are all the same mechanism: stars in the false ground are outliers against the neighbours (a flood of blobs: the old minutes and gigabytes),
the merge erases them (the star loss), and the selective check changes pixels no label explains.

### Measured 2026-10-26: the frames themselves can say "this is not ground"

Per-row star residual of the 19 JPEG frames against their temporal median (frame minus median, minus a 7x7 box blur, positive part, mean over frames; frames at 1/4 size; numpy, no star run):

| rows (fraction of height) | full `a7sii_10` (real horizon at ~0.80) | `a7sii_10_crop16` (sky only) |
|---|---|---|
| 0.00-0.50 | 2.2-2.5 | 2.6-2.8 |
| 0.50-0.75 | 1.9 falling to 1.2 | 2.5 falling to 2.0 |
| 0.80-1.00 (ground / "ground") | **0.29-0.46** | **1.5-1.8** |

Below the real ground edge the residual is 12-19% of the sky's; in the crop it never falls below ~55% of the sky's, including in the region the detector calls ground (its fake line sits at 14-49% of the height). A rule
"mean residual below the detected line / mean residual above it > ~0.5 means the line is not a horizon" has a margin of about 0.19 against 0.85 on these two. **Not yet measured**: a moonlit or lit ground (noise-limited
residual could be a sizeable fraction of the sky's), a windy foreground, and the other static sequences; a heavy-tail (star-like) statistic rather than a mean would be the safer form. The check belongs in `FrameHorizonProcessor.temporalStaticHorizonImage`,
which already holds the sampled `images` and the median `clean`; the outcome it needs is "no horizon" (all sky), which the pipeline already supports through `--no-horizon`.

### How to reproduce

```bash
for f in test_data/test_a7sii_10/*.jpg; do magick $f -crop 2300x1450+1500+600 +repage -depth 16 -compress lzw /tmp/crop/$(basename ${f%.jpg}).tif; done
cli/.build/release/star -c automatic:false /tmp/crop /tmp/out            # stars lost below crop y ~500
cli/.build/release/star -c automatic:false --no-horizon /tmp/crop /tmp/out2   # stars kept
# measure with: star-removal-verify ... --stars, with a "sky" polygon in labels.json limited to a band
```

### Where to look

`StarCore/Sources/StarCore/CombinedHorizonDetector.swift` and the methods it combines (`dp`, `tex`, `grad`, `siox`, Otsu): a confidence for "no horizon", or a check that the
proposed ground differs from the sky (stars move between frames, the ground does not: the per-pixel temporal variance across the neighbours separates them without any image model).

### Referenced from

* `gherkin/removal-thresholds.json` (the star thresholds are only valid for sequences with a real horizon, or with `the frames have no horizon`).
* `gherkin/measure-removal.sh` (`MEASURE_CROP=1` runs the crop with `--no-horizon`).

### Status

Open. Workaround: tell Star there is no horizon (`--no-horizon`, or the Gherkin step `the frames have no horizon`).

---

## BUG-004: per-object removal verdicts differ between platforms and runs while the totals stay put

Found 2026-10-15 comparing the macos-15 (GPU) and ubuntu-24.04 (CPU) CI runs on the full-frame `a7sii_10` JPEG set.

### What was observed

Same 226 measurable labelled objects, same source. Counting an object removed when its median stretch ratio is below 0.5:
* `automatic:false`: 226 removed on both, no object differs.
* `automatic:true`: 188 (macos) vs 189 (linux) removed, **7 individual objects differ** (`00084-12`, `00085-15`, `00086-14`,
  `00088-12`, `00092-6`, `00094-7`, `00096-5`).
* `selective`: 47 removed on both, **2 objects differ** (`00084-12`, `00092-6`).

### Measured 2026-10-26: not run-to-run, and not GPU versus CPU

On the iMac Pro (Vega GPU), `a7sii_10` JPEG, `-c automatic:true`, three runs: **two GPU runs are byte-identical on all 19 output frames**; a **CPU-only run
(`--no-use-gpu --no-use-gpu-for-sift --no-use-gpu-for-akaze`) agrees with the GPU run on every one of the 226 objects (0 verdict differences, largest median-ratio difference 0.004)**.
So the 7 objects that differ between hosted macos-15 and ubuntu-24.04 come from the platforms: different CPU architecture (arm64 against x86-64), different OpenCV builds and SIMD paths, floating-point
differences in alignment and in the decision-tree features. Within one platform the result is stable (that is what the pins rely on).

### Measured 2026-10-26: the differences are whole-group flips, not small numeric drift

Develop run 40400376618, `autoPreservationKeepsAirplanesOutJpeg` (`automatic:true`), macos-15 against ubuntu-24.04, per-object median stretch ratio over the 234 objects both runs could measure:
median absolute difference 0.006, 229 objects within 0.08, and **5 objects that differ by 0.8 to 1.03**: `00095-5` (mac 1.03 / linux 0.00), `00091-5` (mac 0.00 / linux 1.03), `00091-4` (1.02 / 0.01), `00088-12` (0.98 / -0.02),
`00093-6` (1.02 / 0.22). Each flips between "removed" and "left in", in both directions (not one platform always removing more). So what differs is a group's keep/remove decision (a classifier score near its threshold, or a group split or merged
differently by the blob stage), not the pixel arithmetic after that decision. The artifacts hold only the verifier reports, not `OutlierGroupPaintData.json`, so the scores themselves are still unseen.

### What it means (hypotheses, not yet separated)

Cross-platform floating-point sensitivity in the keypoint/alignment stage or in the classifier's features; a borderline classifier score near the decision threshold for those 7 objects flips with a tiny numeric difference.
To separate: dump the classifier scores of the 7 objects on both platforms (`-w --keep-temp-files`, then `star-removal-verify --temp`, which prints the scores) and see how close to 0 they are.

### How to reproduce

Run the measurement workflow (`.github/workflows/removal-measure.yml`) and compare the `report.json` objects between the two artifacts; or run the same
`a7sii_10` configuration twice on one machine and diff.

### Where to look

`OutlierGroupPaintData.json` under `-w --keep-temp-files` on each platform for one of the objects above; `FrameAirplaneRemover.swift` classification path.

### Referenced from

* `gherkin/removal-thresholds.json` `removed_fraction_min`.

### Status

Open, low priority: the pins and the aggregate check already tolerate it. Narrowed to a cross-platform numeric difference; next step is comparing the 7 objects' classifier scores on macOS and Linux CI.

---

## BUG-005: `star -c selective` crashed with SIGSEGV on a hosted macos-15 runner while merging horizons (intermittent)

Found 2026-10-16 in the first CI run of the removal features on PR 14 (Gherkin run 38832664368, job `cli (macos-15)`).

### What was observed

`testSelectiveRemovesOnlyTrailsFeature` (selective on `a7sii_10_16bit`, release cli, no other flags except `-l info -c selective`) failed with
`star exited 11` after 47 s. The log ends with:

```
FrameHorizonProcessor.swift@268: frame 0 making merged horizon
FrameAirplaneRemover.swift@101: frame 0 transitioning to state mergingHorizon
FrameHorizonProcessor.swift@352: frame 0 making merged horizon 19 neighboringHorizons
FrameHorizonProcessor.swift@470: frame 0 saved median horizon as global reference .../star_temp_a7sii_10_16bit/mergedHorizon...
*** star has crashed ***
signal: SIGSEGV (invalid memory access)
```
All 19 frames had reached `horizonDetected` first. The other four features in the same job (same binary, same runner, `automatic:false` on a7sii_10,
`automatic:true` on a7sii_10 and a7sii_10_16bit, the plain open-and-process) passed, and this same selective configuration on this dataset ran
cleanly in three other runs on macos-15 (measurement run 38823906748: selective, selective repeat, selective CPU-forced) and on ubuntu-24.04 and
locally. So it is not deterministic.

### Measured

2026-10-26: **not reproduced locally in 12 of 12 runs** (iMac Pro, release cli built that morning, `-l info -c selective` on a 16-bit TIFF copy of the 19 `test_a7sii_10` frames made with
`magick -depth 16 -compress lzw`, a fresh copy each run, each run left going for 25 s past the "saved median horizon as global reference" line or until it exited; none crashed). That leaves the memory-pressure and
paravirtual-GPU hypotheses (a 7 GB / 3-core VM) as the live ones, and a hosted-runner-only race that a 36-thread machine does not hit. Only the log above. No crash report or `star_temp` directory was captured (the runner deletes it). Hosted macos-15 VMs have little RAM
(see the memory-gate comments in `.github/workflows/gherkin.yml` for the desktop leg) and expose a paravirtual GPU.

### What it means (hypotheses, not yet separated)

A race or use-after-free in the merged-horizon step (several frames' horizon tasks run concurrently); a memory-pressure failure on the 7 GB VM
(SIGSEGV from an unchecked allocation); or the paravirtual-GPU path. Nothing here distinguishes them.

### How to reproduce

Re-run the `cli (macos-15)` job of the Gherkin workflow a few times and see whether it recurs. Locally: `star -l info -c selective <fresh copy of a7sii_10_16bit> <out>` in
a loop; set the diagnostic log (`-f debug`) so the crash details are kept (the message says they are reported on the next run).

### Where to look

`StarCore/Sources/StarCore/FrameHorizonProcessor.swift` lines ~268 to ~470 (merged horizon and the global reference), `RunMarker.swift` (crash markers).

### Referenced from

None. It makes `selectiveRemovesOnlyTrails` flaky on macos-15 until understood.

### Status

Open. Seen once in three macos-15 runs of that feature (run 38832664368 failed; the same job passed in 38838922701 and 40259054830); not reproduced locally.

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
