# Gherkin removal validation: result

`GHERKIN_REMOVAL_VALIDATION_PLAN.md` has been removed. Only the parts that need no real labelled data, CI runs or
Brian's decisions were built. Nothing is committed.

## What was built

**`trail_tools/`** (standalone SwiftPM package, swift-tools-version 6.0):
- `RemovalCore`: pure Swift with no OpenCV, so its tests build anywhere. It holds the trail-contrast check (50 px stretches,
  on-line vs background bands, 5σ measurability, >20% unmeasurable = label error), the star-flux distribution check, the
  `--unchanged-outside` connected-component report, differential mode, the thresholds model, the baseline ratchet
  (known failure / regression / fixed-must-be-removed), the PNG crop writer, and the seeded trail generator.
- `RemovalIO`: decodes and encodes through StarCore's `PixelatedImage` and `MatWrapper`.
- `star-removal-verify`: all the options in the plan except `--temp` diagnostics (below). It exits 0, 1 or 2 as specified.
  `--report-only` is supported.
- `star-trail-inject`: seeded and deterministic. It writes `base/` (byte copy), `injected/` (16-bit TIFF) and `labels.json`
  (confirmed). It builds satellites (SNR sweep, FWHM 1.5–3, some collinear continuations into the next frame), airplanes
  (twin lines, strobe dots, red/green/white tint, some running off the edge) and meteors (tapered).
- 17 XCTests (`swift test` in `trail_tools/`) pass: known line ratios, partial removal, the worst stretch, faint trails,
  star flux scale and lost stars, an unlabelled blob reported as one component with the right area, the refusal rules for
  `--unchanged-outside`, the baseline ratchet, and label errors.

**`tools/label-trails/index.html`**: the labelling page (no build, no network). Zoom, pan, polyline points, class, width,
note and confirmed per object; drafts are drawn orange; it loads and exports `labels.json`, and draws a `sky` polygon.
It was not exercised in a browser.

**`gherkin/removal-thresholds.json`**: every value is `null` with a `measured` note. **`gherkin/removal-baseline.json`**:
empty. **`gherkin/README.md`**: a new section covering labels, the verifier, thresholds, the baseline and synthetic data.

## Checked by hand

I built a 3-frame 2000×1400 16-bit TIFF base from `test_a7sii_10` and injected 17 objects. With the output set to the base
(trails gone), the measurable objects came out at worst ratio 0.01–0.09. With the output set to the injected frames, they
came out at exactly 1.000. The stars check gave a ratio of 1.000 on identical frames (about 6000 peaks per frame).

**Finding for Phase 4:** the 5σ measurability rule on a median of on-line pixels classes synthetic satellites at SNR 3, 5 and
10 as unmeasurable (label error) and the tapered meteors as partly so. Only SNR 30 and 100 satellites and the airplanes
(SNR 40) are measured. If the SNR sweep is meant to reach the low end, the metric, the width or the SNR definition needs
changing. Do not just loosen the 5σ rule.

## Phase 1 validation against frame 92 (done)

All 19 `test_a7sii_10` frames converted to 16-bit LZW TIFF, a one-object hand-drawn label
(`(548,312.2)→(999,412.1)`, width 8, confirmed only in a scratch copy; the committed form would stay a draft). Release cli,
fresh input copy per run, verifier `--expect airplane=removed`:

| run | worst stretch ratio | best | known value |
|---|---|---|---|
| `automatic:false` | 0.008 | −0.021 | −0.009 (worst 0.040) |
| `selective` | −0.024 | −0.065 | (not previously measured) |
| fixed `automatic:true` | 0.129 | −0.021 | 0.006 (worst 0.130) |
| old `automatic:true` (`1b2cb327^`) | 1.057 | 1.031 | 1.03 |

The fixed `automatic:true` worst stretch (0.129) matches the 0.130 in the plan, and the old build gives 1.03 to 1.06. The
worst/best columns are per-stretch extremes, so they are not directly comparable to the plan's averaged figures
(−0.009, 0.006); the scale and the separation between removed and not removed (0.13 vs 1.03) hold. Metal was in use by
default on this Mac. Wall times: 59 s, 74 s and 82 s respectively.

## Real labels received (2026-10-15)

`test_data/labels/a7sii_10.labels.json` (copied from Brian's export; source for the future archive): 240 objects, all
`confirmed`, `complete: true`, all class `airplane`, all width 8. Observations:
- Every object has the default class. Faint streaks that are satellites are probably still `airplane`. Needs a pass.
- One short object (11–33 px) appears in nearly every frame and drifts steadily from (940,2229) to (730,2325): a slow moving
  point, not a trail. Two more short ones: `00086-14`, `00095-3`.
- Metric change made because of this data: the original single wide on-line median left 227 of 240 objects "unmeasurable"
  (a thin faint streak is averaged away by an 8 px band). The on-line value is now the peak of 1 px lateral bins (bin chosen
  on the input, output read at the same bin; tolerates clicks a few px off) and measurability is 5σ of a median over that
  bin's pixels. 226 of 240 are now measurable; 14 are label errors. The frame-92 numbers above were taken with the *old*
  metric and have not been re-run with the new one.
- Measured on the 16-bit TIFF conversion of the sequence (release cli, this Mac), worst-stretch ratio per object:
  - `selective`: bimodal. 49 objects ≈ 0 (removed), 177 ≈ 1.0 (not removed). Removed ones are the bright streaks (median
    input contrast 0.14 vs 0.05 for the untouched ones). Only 1 object is partially removed.
  - `automatic:false`: median 0.08, p95 0.35, max 0.62 (a noise floor of about ±0.2 on the worst of several stretches).
  - `automatic:true`: 158 of 226 near 0–0.2, 33 near 1.0 (restored as keep), a tail between.
- `--unchanged-outside` on `selective` (labels are complete and input is lossless): 0 changed pixels outside the labelled
  trails in 4 of the 19 frames, 39–1073 px (3–52 small components) in the other 15, out of 12 MP per frame. The labels
  account for nearly everything Star removed. Crops were not reviewed.
- Consequence: on real data `selective` fails most labelled faint streaks, so a baseline would hold about 177 entries. Whether
  those are "known failures" or mislabelled/should not be required is Brian's call before any baseline is written.

## Datasets built (2026-10-15, after merging develop with the speed/test-data work)

Archives are in `.test-data/upload/` (git-ignored) and the manifest `test_data/datasets.json` is edited. **Not uploaded: Brian
must run `gh release upload test-data <asset> --repo brianm998/starry_timelapse_airplane_remover` for both before pushing,
or every leg that uses `data:a7sii_10` fails to fetch.**
- `a7sii_10-2b6cb64824f4.tar.gz` (46,412,100 B): the original 19 JPEGs plus `labels.json` (Brian's 240 objects). The manifest's
  `a7sii_10` entry now points at it; the old unlabelled asset stays on the release. Star ignores the extra `labels.json`
  (it only reads supported image types).
- `a7sii_10_crop16-349ca66e8f0f.tar.gz` (132,881,491 B): 16-bit LZW TIFFs, every frame cropped to x=1500 y=600 w=2300 h=1450
  (all sky, no ground, contains the bright airplane and a satellite streak in frame 92), plus `labels.json` shifted into crop
  coordinates and clipped at the crop edge: 122 objects, 31 clipped, 118 of the 240 lie wholly outside. Pieces under 8 px
  were dropped. `complete` was carried over from Brian's full-frame label set. Copies of both label files are in
  `test_data/labels/`.

First run on the crop (`selective`, release cli, this Mac): 122 objects, 5 label errors (50% or less measurable), 11 removed,
106 not removed (faint ones, as on the full frame). `--unchanged-outside`: 10 of 19 frames have changed pixels outside the
labels, total area 44,022 px. **One frame dominates:** frame 90 changed 28,655 px in 56 components, the largest a band at
crop x 934–2265, y 550–700 (full-frame y about 1150–1300). Viewing it, Star repainted a wide stretch of dense Milky Way with
smeared diagonal streaks, and no trail is visible in the input there. Either an unlabelled very faint trail or a false
positive that damages the frame. Brian should look at `LRT_00090` in that band. The verifier does what it is meant to do here;
I did not change Star. This is also why `complete` on the crop set is only as good as the full-frame labelling.

Not verified: the run took 30 minutes of wall clock on the crop (the full-size run took 82 s), with the machine at load average
~200 from other work, so the slowdown is not attributed. The new `min_required_contrast` threshold (faint objects are reported,
not required; `faint` status; unit tested) is in the verifier but its value is unmeasured and the removed/kept contrast
distributions overlap (see `removal-thresholds.json`).

## Frame 90 recorded as a known issue (2026-10-15)

Brian chose "record it as a known issue". Further analysis of the report overturned my first guess ("no trail visible, probably
a false positive"): 97% of frame 90's changed area (27,752 of 28,655 px) lies on one straight line,
y = 0.0987·x + 469.8 in crop coordinates, residual under 2 px, over ~1,340 px. So Star removed a real, faint, unlabelled
linear object, and the repaint leaves smeared streaks in the Milky Way. It is written up as **BUG-001 in `BUGS.md`** (new
file; multi-bug format with a template and add/delete rules). The baseline gained a `collateral` section
(`gherkin/removal-baseline.json`, one entry for `a7sii_10_crop16` / `LRT_00090.tif` / `selective`): such a frame's area is
reported but left out of the unchanged-outside total, and the verifier fails once it is within the limit, telling you to
remove the entry (unit tested; 19 tests pass). Still open for Brian: label that trail (full-frame (2434,1162) to (3765,1293)),
which would also clear the entry.

## Phase 4 measurement workflow (written 2026-10-15, never run on CI)

Brian uploaded both archives; `gh release view` shows sizes and sha256 equal to `datasets.json`. (A real download could not be
tested from my sandbox: it rejects GitHub's certificate, so run `test_data/fetch.sh a7sii_10 a7sii_10_crop16` once.)

`.github/workflows/removal-measure.yml` (manual `workflow_dispatch` only; a measurement, not a gate) has a job on `ubuntu-24.04`
and one on `macos-15`. Each fetches the datasets, builds `star` and `trail_tools` in release, runs the verifier's unit
tests, then `gherkin/measure-removal.sh` runs `a7sii_10` (JPEG) and `a7sii_10_crop16` (16-bit) with `selective`,
`automatic:false` and `automatic:true` through `star-removal-verify --report-only --stars` (plus `--unchanged-outside` for
selective on the crop set; on macOS also a CPU-forced repeat with `--no-use-gpu*`). `gherkin/measure-removal-summary.py`
turns the reports into a markdown table (worst-stretch ratio quantiles, star-flux ratio, lost-star fraction, unchanged-outside
area, removed-vs-kept input-contrast quantiles) in the job summary; reports, crops and logs are uploaded as artifacts. Star runs
with `-l info` so the GPU decision line ("GPU acceleration … is on (device)" or the CPU fallback) lands in `gpu.txt`.

Smoke-tested locally on macOS only (one run, `a7sii_10` `automatic:false`, via `MEASURE_FILTER` and `STAR_TEST_DATA`): the script,
verifier and summary run end to end; star flux median 0.964 (earlier measurement 0.961); GPU line captured. The YAML parses; it has
not been run by Actions, so expect to fix a step on the first run.

**Windows is not measured.** There is no `star` cli build for Windows in this repo (only `stard`, in the desktop leg), so the
cli-based suite cannot run there. The plan scopes the removal suite to the cli on Linux and macOS. Windows uses the CPU path like
Linux, so Linux numbers should represent it, but that is unproven. Phase 5 should still build `trail_tools` on the Windows
leg (cheap compile check) if that leg can run the verifier at all.

## Phase 4 results (CI runs 38798344452 macos-15 and 38801175389 ubuntu-24.04, 2026-10-15) and what they changed

Full tables are in the job summaries and the `removal-measurements-*` artifacts. Headline findings:
- **`a7sii_10` (full-frame JPEG, 240 labels, 226 measurable) is stable across macOS (Metal-paravirtual GPU path) and Linux (CPU):**
  `automatic:false` removes 226/226 on both (median stretch ratio max 0.312); `automatic:true` 188 vs 189; `selective` 47/47.
  Star flux ratio medians 0.933 to 0.994 (automatic), 1.002 to 1.004 (selective), lost fraction at most 0.014, identical on both OS.
- **Metric change:** the pass rule is now the per-object **median** stretch ratio, not the worst stretch, because worst-stretch
  distributions of removed and kept objects overlap (0.46 to 0.48 vs 0.52 to 0.58) and the median ones do not
  (removed at most 0.48, kept at least 0.81). New verifier options `--aggregate` (judge the fraction removed;
  `removed_fraction_min`) and `--skip-unmeasurable` (faint hand labels are skipped, not label errors). 21 unit tests pass.
- **Thresholds set with evidence** in `gherkin/removal-thresholds.json`: `removed_max` 0.6, `kept_min` 0.7, `stars_median_min` 0.9,
  `stars_median_max` 1.05, `stars_lost_max` 0.04, `removed_fraction_min` 0.7. Still null: `unchanged_outside_max_area`,
  `differential_outside_max`, `min_required_contrast` (brightness does not predict selective removal: 12 of 19 streaks at contrast >= 0.3 removed).
- **The hosted macos-15 runner reports a GPU ("Apple Paravirtual device") and uses it**, so macOS CI does exercise the GPU path.
  CPU-forced and GPU runs on the same runner differ on the crop set (collateral 14,419 vs 45,771; 3 objects flip).
- **The crop dataset `a7sii_10_crop16` is a poor fixture**: stars lose 30 to 70% flux under `automatic:false` (BUG-002), `selective` and
  `automatic:true` take 25 to 35 min per run (BUG-003), and `selective` is non-deterministic: the same machine twice gave 44,022 then
  80,826 changed px, with frame 90 going 28,655 to 903 (BUG-001, which replaces my earlier "frame 90 is damaged" read; the frame-90 baseline
  entry was removed because it does not reproduce). Per-object verdicts also differ between OS for 7 objects under `automatic:true` (BUG-004).
- **Replacement: `a7sii_10_16bit`** (full-frame 16-bit LZW TIFF, same labels, 411,344,795 B). Locally `selective` run twice gives 19/19 identical
  frames, 6,723 changed px in total: reproducible. Built into `.test-data/upload/` and the manifest; **not uploaded**. The measurement
  workflow now fetches `a7sii_10` and `a7sii_10_16bit` and also runs `a7sii_10_16bit selective` twice plus a macOS CPU-forced repeat, to measure
  same-platform repeatability and set `unchanged_outside_max_area`. The crop is still in the manifest and reachable with `MEASURE_CROP=1`.

## Phase 5 (cli) done locally, not yet run on CI

Commit `558e2831` and the work after it. New steps in `gherkin/steps.json`: `openSequence16` (`I open the 16-bit sequence {sequence16}`),
`the clean method is automatic:false|automatic:true|selective`, `the labelled airplanes are removed`, `the labelled satellites are removed`,
`the stars are preserved`, `nothing outside the labelled trails changed`. **Deviation from the plan's step table:** the clean method and the
dataset are separate literal steps / placeholders, because a `{placeholder}` has one value per client and the features need different ones.
`processWithBase` is not added (no synthetic dataset yet). Features (all `@cli`, all pass locally, 5 of 5 together, release cli on this Mac):

- `removeAirplanes`: `automatic:false` on `a7sii_10`: 226 of 226 measurable airplanes removed, stars preserved.
- `autoPreservationKeepsAirplanesOutJpeg` / `...Bit16`: `automatic:true`: fraction removed 0.83 (>= 0.7) and 42 pinned objects removed.
- `selectiveRemovesOnlyTrails`: `selective` on `a7sii_10_16bit`: pinned objects removed, 6,723 changed px outside the labels (<= 25,000), stars preserved.

Verifier additions: `--aggregate`, `--skip-unmeasurable`, `--pins` / `--pins-only` (pinned objects: `gherkin/removal-pins.json`, 43 objects, derived from
Star's own output and kept only if removed in all 7 selective and 5 automatic:true runs I have), median pass rule; 23 unit tests pass.
Why pins: the removed fraction cannot tell the pre-`1b2cb327` build (0.78) from the fixed one (0.83).

**"Deliberately broken removal turns the right feature red", proven locally** (throwaway builds, not a commit):
- pre-`1b2cb327` build, `autoPreservationKeepsAirplanesOutBit16`: red, 45 of 46 pins came back (before 3 unstable pins were dropped); that feature's fraction check alone passed.
- `selective` with the selection inverted (`!reason.willRemove` in `computeRemovalMask`): `selectiveRemovesOnlyTrails` red, 43 of 43 pins failed, with the per-object lines and crops.
- The pre-fix build passes `selectiveRemovesOnlyTrails`, correctly: the bug is only in `automatic:true`.

CI: `gherkin.yml` cli legs build `trail_tools`, run all five tests, the guard greps each test name and `Executed 5 tests, with 0 failures`, require the
report JSON to exist, and upload `removal-reports` with `if: always()`. **Not run on CI yet**; the first push will show whether the removal steps behave
on hosted runners (Linux and macOS times are expected at roughly 10 to 15 minutes more per leg, about 9 minutes locally for the five).

## Merge with develop's scenario matrix (2026-10-25)

develop gained the scenario-matrix work (its own `removal_tools` with `star-output-verify`, per-feature params, one CI job per feature, setting steps and the
ordering rule). This branch's package moved to `trail_tools/` (it is `star-removal-verify` and `star-trail-inject`) and develop was merged in keeping both.
What changed here: the four removal features use develop's vocabulary (horizon, camera, clean method, open, process, `the run used the requested settings`,
then the removal Thens) with their `sequence` under `features` in `params.json`; `openSequence16`, `outputFramesWritten` and this branch's three clean-method
steps are gone (`openAndProcess.feature` went with develop's matrix); the runners are develop's with the removal steps added and the verifier mode taken from
the run's own clean step. **So the GUI clients now run `removeAirplanes` in automatic mode through the startup prompts, and the desktop special case below
(selective default, pins only) no longer applies to that feature**; the desktop runner still seeds DETECTION_STRONG for removal features. `gherkin.yml` is
develop's matrix workflow plus a gated "trail verifier" build step. Local checks after the merge: generate.sh leaves no diff; the Kotlin gherkinTest sources, the
Xcode UI-test target and the cli test target compile; `swift test` in `trail_tools` passes (23 tests). **Not run:** any scenario, and nothing on CI after the merge.
The sections below describe the state before it.

## GUI clients (`@mac-gui`, `@desktop`), 2026-10-16

`removeAirplanes` is now tagged `@cli @mac-gui @desktop`. `GuiFeatureRunner.swift` and `DesktopFeatureRunner.kt` implement `airplanesRemoved`, `satellitesRemoved` and `starsPreserved`, with the cli runner's verifier flags
(`--skip-unmeasurable`, `gherkin/removal-thresholds.json`; `--clean-method automatic:false` on the mac GUI, `selective --pins-only` on the desktop client) and guards (objects == confirmed labels, > 0 measurable, star
frames == output frames). XCUITest can launch a subprocess, but I was wrong that its runner is unsandboxed: CI showed it cannot write into the repo ("Operation not permitted" creating `removal-reports`), so the mac GUI's reports go to a temp directory and are attached to the xcresult. No
separate CI step was needed. `gherkin.yml`: every GUI leg builds `trail_tools`, the guards now expect two tests (`Executed 2 tests` / `tests="2"`), name
`testRemoveAirplanesFeature` / `removeAirplanesFeature`, require the report JSON (the mac GUI: its summary line in the log) and upload `removal-reports-desktop-<os>`.

What was verified: generated files regenerated; the Kotlin `gherkinTest` source set compiles (`./gradlew compileGherkinTestKotlin`); see below for the Xcode build.
What was **not** run: neither GUI scenario has executed (no XCUITest run, no Compose run, no stard run with this feature), nothing on GitHub Actions, and the
verifier has not been built on Windows. Expect the GUI legs to take roughly 5 to 10 minutes longer each (verifier build and the verify pass).

CI correction (run 38832664368): the first version hardcoded `automatic:false` for the desktop client, whose default is `CLEAN_SELECTIVE`, and failed with
48 of 226 removed (the selective profile). Fixed by dropping `the clean method is automatic:false` from `removeAirplanes.feature` (each client runs its default)
and judging the desktop run with the selective mode (pins only). The mac GUI's default was checked in `StartupView.swift` and is `automatic:false`.

## First CI run of the removal features (PR 14, Gherkin run 38832664368 on 4d0a77fa, 2026-10-16)

- **cli (ubuntu-24.04): all five features passed.**
- **cli (macos-15): four passed** (removeAirplanes 226/226, automatic:true fractions 0.823 and 0.832 with 43/43 pins, open-and-process), **one failed because `star` crashed**: `selectiveRemovesOnlyTrails`, SIGSEGV 47 s in during horizon merging. Intermittent (same binary, dataset and runner type passed in three earlier runs). Recorded as BUGS.md BUG-005. Not a defect of the check.
- **cli (windows-2022): `trail_tools` builds and the verifier runs on Windows.** removeAirplanes passed (226/226), the JPEG automatic:true feature passed, the open-and-process feature passed; the two 16-bit features failed on one pinned object, `00091-5` (median ratio 1.0, not removed on Windows CPU). Fix: that pin was dropped (42 pins now). Thresholds otherwise hold on Windows: stars passed, fractions 0.836.
- **desktop (ubuntu-24.04): `removeAirplanes` failed** (48 of 226 removed, the selective profile): the desktop client's default clean method is selective, not automatic:false, so the GUI runner's hardcoded method was wrong. Fixed in 1ea45863 (the desktop is judged with the selective pins-only check; the mac GUI's default really is automatic:false). The fix and the pin change are not yet on CI.
- Still pending on that run when this was written: desktop (windows-2022), desktop (macos-15), mac gui.

### Second CI run (6a164468)

`cli (macos-15)` passed all five (the SIGSEGV of the first run did not recur: BUG-005 is intermittent). `desktop (ubuntu-24.04)` ran the selective pins-only check with the clean-method fix and left 5 of the 42 pins in place, all faint
(input contrast 0.025 to 0.071; every pin at >= 0.075 was removed). The GUI session's diagnosis: the desktop session ran at detection type MILD while the pins were measured at STRONG (the cli default), and it set STRONG in the desktop runner
(177e93f9). Unproven until CI runs it. I had trimmed the pins by brightness instead (36 left) and reverted that so the STRONG fix is tested on its own; that brightness cutoff is the fallback if the desktop still misses the faint pins.

### Third and fourth CI runs (43939fe6, 8cb892c8)

On 43939fe6 the desktop STRONG fix worked on all three desktop legs (so MILD vs STRONG was the real cause, not brightness), and every leg was green except `mac gui`: the sandboxed XCUITest runner could not create `removal-reports/` in the repo (Cocoa error 513). On 8cb892c8 (reports and crops written to the sandbox temp dir and attached to the xcresult) **`mac gui` passed: the verifier launches from inside the sandboxed UI test and `removeAirplanes` removed 226 of 226 measurable airplanes there.** Also green on 8cb892c8: cli on Linux, macOS and Windows, desktop on Linux and Windows. **`desktop (macos-15)` failed** on a "detection type not written to the session config" check that races a starved daemon (2.7 GB free, keypoint-slot timeouts); it had passed on 43939fe6. The GUI session reworked it (bd7dc48b: seed STRONG through the remembered-preference file, only verify it), unpushed and unproven when this was written.

## Not done (leftover)


- **Synthetic datasets**: `star-trail-inject` exists and was smoke-tested, but no synthetic dataset has been built, proven clean with Star, uploaded or measured, so there is no `processWithBase` step and no `syntheticSatellites` / `syntheticAirplanes` feature, no differential threshold, and the plan's realism comparison (synthetic vs real detection rate) was not done. There is also no satellite feature (no object is labelled `satellite`).
- **`--temp` decision diagnostics** are not implemented (the option is accepted and prints a note). The cli runner does not pass `-w --keep-temp-files`.
- **Windows**: no `star` cli there. The desktop-windows leg now runs `swift build -c release` in `trail_tools` (StarCore builds there as part of stard, but `trail_tools` itself has never been built on Windows) and `removeAirplanes` runs there through the Kotlin runner. **Not run.** If that build fails, that leg fails at the new step.
- **BUGS.md** BUG-001 to BUG-004 are open and unassigned: `selective` is non-deterministic on the cropped set, stars are dimmed on it, it takes 25-35 minutes, and per-object verdicts differ between platforms. `a7sii_10_crop16` stays in the manifest but nothing uses it.
- `trail_tools/Package.resolved` is committed as generated and was not reviewed. The `removal-measure.yml` workflow still has a temporary `push` trigger and a `[skip macos]` switch to delete when it is merged.
- The pins and thresholds come from one day of runs (one CI run per OS plus local runs): re-measure if a platform or a Star change moves them.
