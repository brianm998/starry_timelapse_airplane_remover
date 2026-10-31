# release-stats

GitHub only keeps a running download total per release asset, and 14 days of repo traffic. `stats.py` snapshots both
every day, so the totals become a history (new downloads per week or month) and the traffic outlives its 14 days.

## How it runs

`.github/workflows/stats.yml` runs daily (06:17 UTC) and on demand from the Actions tab. It adds the day's snapshot to
CSV files on a separate **`stats`** branch, so the commits stay out of `develop`, and regenerates that branch's
`README.md`, which is the latest report. Each run also puts the report on its summary page.

The workflow creates the branch on its first run. Scheduled workflows run only from the default branch, so nothing
happens until the workflow is merged to `develop`. History starts at the first snapshot: GitHub has no earlier download
data to backfill, only the 14 days of traffic.

| file | one row per | holds |
|---|---|---|
| `downloads.csv` | snapshot day, release asset | cumulative download count |
| `repo.csv` | snapshot day | stars, forks, watchers |
| `views.csv`, `clones.csv` | calendar day | count, uniques |
| `referrers.csv`, `paths.csv` | snapshot day, referrer or page | views over the 14 days to that snapshot |

## Reading it

```bash
tools/release-stats/stats.py report
```

fetches `origin/stats` and prints the markdown report. Or open the `stats` branch on github.com. The report has all-time
and last 7 / 30 day downloads by platform and by product (SwiftUI app, Kotlin desktop, cli), per release, weekly traffic,
referrers and popular pages.

- Only `release/*` tags count as the product. `test-data` and `ci-assets` hold fixtures that CI downloads on every run
  (about 1,500 downloads, against about 240 for the product), so they are reported on one line.
- Growth is the difference between snapshots. A figure marked `*` covers the snapshots there are, because the history
  is shorter than the window. An asset that is deleted and uploaded again starts from 0, and that drop is counted as
  no downloads, not negative ones.
- Unique visitors cannot be added across days. The traffic table says "viewer-days" for the sum of daily uniques.

To work from a local copy instead, or without a `stats` branch:

```bash
tools/release-stats/stats.py collect --data DIR     # needs `gh` logged in, and push access for the traffic
tools/release-stats/stats.py report --data DIR
```

Re-running `collect` on the same day replaces that day's rows.

## Traffic

The traffic API (views, clones, referrers, pages) needs push access to the repo, and the workflow's built-in
`GITHUB_TOKEN` does not have it. Without more, the workflow still records downloads and stars, and puts a warning on the
run saying traffic was skipped. To record traffic too, add a repository secret named **`STATS_TOKEN`**:

1. github.com → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token.
2. Repository access: only this repository. Repository permissions: **Administration: Read-only** and nothing else.
3. Repo → Settings → Secrets and variables → Actions → New repository secret → `STATS_TOKEN`.

The token is used for the four `traffic/*` requests only. It never pushes: that uses the workflow's own token.
Fine-grained tokens expire, so the traffic columns stop when it does; the run's warning says so.

## What this can't tell you

It counts downloads, not installs or use. Your own downloads, CI and package-manager mirrors all add to the counts, and
a download that is never run is counted. For how many people actually run star you would need telemetry in the app,
which is a separate decision.
