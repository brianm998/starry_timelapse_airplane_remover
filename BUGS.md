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
