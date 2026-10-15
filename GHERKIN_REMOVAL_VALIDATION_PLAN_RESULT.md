# Gherkin removal validation: result

`GHERKIN_REMOVAL_VALIDATION_PLAN.md` has been removed. Only the parts that need no real labelled data, CI runs or
Brian's decisions were built. Nothing is committed.

## What was built

**`removal_tools/`** (standalone SwiftPM package, swift-tools-version 6.0):
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
- 17 XCTests (`swift test` in `removal_tools/`) pass: known line ratios, partial removal, the worst stretch, faint trails,
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
and one on `macos-15`. Each fetches the datasets, builds `star` and `removal_tools` in release, runs the verifier's unit
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
Linux, so Linux numbers should represent it, but that is unproven. Phase 5 should still build `removal_tools` on the Windows
leg (cheap compile check) if that leg can run the verifier at all.

## Not done (leftover)

- **`--temp` decision diagnostics** are not implemented. The option is accepted and prints a note.
- **Upload** of the two archives (Brian). No `labels.draft.json` generator was written: Brian labelled from scratch.
- **Phase 3 realism comparison.** The generator exists, but the synthetic-versus-real detection-rate check was not run. The
  base was not proven clean with Star in selective mode, so `--base-is-clean` was never used.
- **Phase 4.** No measurements on `ubuntu-24.04` or `macos-15`, no Metal vs CPU note, and no threshold or baseline values.
- **Phase 5.** None of the following exists: the six `steps.json` entries, runner changes, the five features, CI wiring and
  artifact upload, vacuous-green guards, and the throwaway "deliberately break removal" proof. The speed/test-data branch
  `claude/gherkin-speed-test-data-8b2cf1` was not merged into this base either.
- Project memory `removal-validation-oracle` was not updated, since there are no thresholds yet.
- `removal_tools/Package.resolved` is untracked and was not reviewed for committing. Linux and Windows builds of
  `removal_tools` were not tried.
