# Gherkin: stop rebuilding the same things in every feature job

Status: proposal (GitHub issue #63, filed as `pipe:proposed`). Measured 2026-10-31.

## Problem

A full Gherkin run is the slowest thing in CI: 94-154 jobs, 760-1,584 runner-minutes, and
128-214 minutes of wall clock (median 174) over the last four develop runs. It is also what
everything else queues behind. The pipeline's CI judge waits up to four hours for it
(`ci_blocking_wait_s`), and CLI Build and pr-gate take 35-112 and 18-43 minutes of wall clock
for only about 17-42 minutes of their own work, because the macOS runners are full of Gherkin.

## What the time is spent on

Each feature on each OS is its own job (about 118 feature jobs, 35 features), and every job
repeats its setup. Summed over all feature jobs, **55% of step time is setup and building,
40% is running features** (the rest is bookkeeping).

Setup share of step time, by leg:

| Leg | Setup share |
|---|---|
| mac gui (XCUITest) | 19% |
| cli, macOS | 39% |
| desktop, macOS | 59% |
| cli and desktop, Ubuntu | 57-59% |
| cli, Windows | 82% |
| desktop, Windows | 86% |

The repeated steps, by cost:

- **`Install MSVC 14.40 toolset`**: median 5.2-5.6 minutes in every Windows job, about 35% of
  all Windows time.
- **`Build the output validator`** (`swift build -c release removal_tools`): 1.2-2.7 minutes in
  every cli and desktop job on every OS; 575 minutes summed over four runs.
- **`Build stard (release)`**: 2.6-3.4 minutes in every desktop job on macOS and Linux; 372
  minutes summed over four runs.
- The trail verifier and, on Windows, the rest of the toolchain are rebuilt the same way.

Only the mac gui leg is mostly tests (75%).

## Why it queues

The macOS legs are about 48% of job-minutes and run roughly 210 feature jobs per run on the
few concurrent macOS runners GitHub gives us: median queue 42-100 minutes (max 186). A
develop push does not cancel older develop runs, so several can overlap (see #62). Path
filters (#61) keep non-program changes out of the queue altogether.

## Why features are separate jobs

`gherkin/README.md`: each feature fetches its own dataset, and a failure shows up as that
feature's own red job. Any fix must keep per-feature results visible and keep the
"Prove the scenario ran" step for every feature.

## Options (cheapest first; likely several tickets)

1. **Windows toolchain.** Cache or vendor the MSVC 14.40 toolset instead of installing it in
   every job. Expected saving: about 5.5 minutes times the Windows job count, with no change
   to what runs.
2. **Build once per OS.** One build job per OS compiles the output validator, trail verifier
   and `stard`, and uploads them as an artifact; feature jobs download instead of building.
   Expected saving: most of the 575 + 372 minutes above, minus artifact download time. Risk:
   artifact size and the Windows/macOS path or signing differences the current per-job builds
   hide.
3. **Shard features per leg.** Run several features one after the other in a job (one setup,
   several features) instead of one job per feature. Cuts the macOS job count, which is what
   queues. Cost: a failing feature no longer has its own job, so each feature needs its own
   step (and `if: always()`) so it still reports individually; a dataset fetch per feature
   still happens. Pick shard counts from measured feature durations so the longest shard
   does not set the wall clock.

Options 1 and 2 are independent of 3; 2 and 3 together give the largest saving.

## Acceptance criteria (for the ticket as filed)

- Over three consecutive Gherkin runs after the change, total job-minutes are at least 40%
  below the 760-1,584 baseline for the same set of features.
- Wall clock of a full run is no longer than before (median 174 minutes).
- Each feature's result is still visible as its own pass or fail, with its "Prove the
  scenario ran" check kept.
- No feature is dropped or changed.

Measure with `gh run view <id> --json jobs` totals before and after, reported in the PR.

## Out of scope

Changing what any feature tests; path filters (#61); cancelling superseded develop runs (#62);
the mac gui leg's XCUITest time itself.

## Open questions

- Does the free tier's macOS runner concurrency change if we move work to larger runners?
  (Not measured; paid runners are a separate decision.)
- Is an artifact shared across jobs of one run fast enough on Windows to beat a cached MSVC
  install? Measure option 1 first.
- Sharding interacts with the dataset fetches (`test_data/`): check whether datasets can be
  shared by features in one shard.
