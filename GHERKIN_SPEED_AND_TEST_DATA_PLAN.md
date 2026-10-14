# Gherkin follow-up: faster macOS legs, and test data outside the repo

Two pieces of work for the agent picking this up, **in this order**. Part 1 is small and lands on
its own. Part 2 builds on it. More `.feature` files come after both, so don't write any here.

Read `gherkin/README.md` first. It describes the pilot this builds on: one corpus, a closed step
vocabulary, typed Swift/Kotlin generated from the Ruby `gherkin` parse, and six CI legs with
vacuous-green guards. Everything below keeps those rules. In particular, **nothing parses a
`.feature` (or any new data file) at test run time** unless this document says so.

## Where things stand (run `38646963066`, commit `ee7e7e80`, 2026-10-14)

All six legs ran their scenario and passed. "mac gui" was marked failed only because its log check
grepped `Test case` where xcodebuild prints `Test Case`; `9ea5f927` fixed that. Job times:

| Leg | Job | Slow step |
|---|---|---|
| desktop (ubuntu-24.04) | 6 min | |
| desktop (windows-2022) | 20 min | MSVC install 5 min, `stard` build 9 min, test 4 min |
| desktop (macos-15) | 16.5 min | |
| cli (ubuntu-24.04) | 10 min | |
| cli (macos-15) | 23 min | **test step 1332 s** |
| mac gui (macos-15) | 30 min | **test step 1728 s; the XCUITest itself took 1495 s** |

Both macOS hot spots process the 19-frame 12 MP sequence with **Debug** builds:

- **cli:** `swift test` runs the debug `star` that SwiftPM builds beside the test bundle
  (`CliFeatureRunner.swift:120`; `STAR_CLI_PATH` overrides it).
- **mac gui:** the `star` scheme's TestAction uses `buildConfiguration = "Debug"`
  (`gui/star.xcodeproj/xcshareddata/xcschemes/star.xcscheme:25-26`). gherkin.yml even has a step
  that symlinks `StarDecisionTrees/{include,lib}/debug/macos` to `release` just so Debug links.

Every future feature that processes frames pays this again, so fix it first.

---

## Part 1: run the macOS legs against release builds

### cli legs (both OSes, but macOS is the one that hurts)

Measure two ways on `macos-15` and keep whichever has the **lower total job time**. Compile time
counts as much as run time:

- **A.** `swift build -c release --package-path cli --product star`, then
  `STAR_CLI_PATH="$PWD/cli/.build/release/star" swift test --package-path cli --filter GherkinTests`.
  This costs a second, debug, compile of everything for the test bundle.
- **B.** `swift test -c release -Xswiftc -enable-testing --package-path cli --filter GherkinTests`.
  The `-enable-testing` is needed because the cli's other test target uses `@testable import star`,
  and `--filter` still compiles every test target. This is one release compile.

`swift build` products need the same `-I<path>` (no space) StarDecisionTrees include that every
cli build uses (see project memory `adding-tests-per-target`). Apply the winner to `cli (ubuntu-24.04)`
too. Keep the README's local command in step with what CI does.

### mac gui leg

- Build and test the app in **Release**: `xcodebuild test -configuration Release …` with the rest of
  the current invocation unchanged (`-scheme star`, `-only-testing:starUITests/GeneratedFeatureUITests`,
  the ad hoc signing settings, no `-destination`, never `-target Star`).
  - XCUITest drives the app from outside the process and never `@testable`-imports it, so Release
    is legitimate.
  - If `-configuration` turns out not to override the scheme's TestAction, change the TestAction's
    `buildConfiguration` instead. Don't create a new scheme.
- Then delete the "Point StarDecisionTrees debug at release" step, if Release no longer needs it.
  Prove that by the leg passing without it.
- Things that may break under Release, so check them rather than assume:
  - hardened runtime or ad hoc signing of the app vs the UI-test runner
  - dead-code stripping removing an accessibility identifier's view (unlikely)
  - the `star` scheme's LaunchAction has `enableAddressSanitizer = "YES"`. Confirm whether
    anything from the LaunchAction leaks into the test run, since TestAction has
    `shouldUseLaunchSchemeArgsEnv = "YES"`.
- Local development keeps Debug as the scheme default. Only CI and the documented "run like CI"
  command pass Release.

### Done for Part 1

- All six legs are green on a PR, with the vacuous-green checks unchanged and still passing.
- A before/after table of per-leg job time and test-step time goes in the PR description.
- If either macOS test step is **still over 10 minutes**, find out where the time goes before
  moving on: sample the running process, or time the steps inside the runner. Report it rather
  than guessing.
- Merge Part 1 before starting Part 2.

---

## Part 2: test data from a manifest, hosted on GitHub Release assets

### Why this design (decided, don't re-litigate)

- **Host: GitHub Release assets** on this public repo.
  - The repo already does this: the gui's 386 MB splash video lives in the `ci-assets` release, and
    CI fetches it with `gh release download`.
  - It's free, needs no new account, and anyone can download anonymously with
    `curl -L https://github.com/brianm998/starry_timelapse_airplane_remover/releases/download/<tag>/<asset>`.
  - Each file must be **under 2 GiB**. Anything bigger is out of scope for now; flag it rather than
    splitting it.
- **Rejected:**
  - Git LFS: every CI download draws on the LFS bandwidth quota, worktrees need LFS setup, and the
    desktop app's `sync_with_base_branch` refuses LFS-filtered repos.
  - A data submodule: same per-file limit and history growth as now.
  - S3/R2: the upgrade path past 2 GiB, not needed yet.
- **The committed `test_data/test_a7sii_10` (44 MB) stays in the tree for now.** Deleting it
  wouldn't shrink the clone, because it's in history. Other things still read it (listed under
  "Out of scope"). The Gherkin features stop using it.

### Pieces to build

**1. Manifest: `test_data/datasets.json`.** It is the single source of truth for every
out-of-repo dataset:

```json
{
  "release": "test-data",
  "datasets": {
    "a7sii_10": {
      "asset": "a7sii_10-<first 12 hex of sha256>.tar.gz",
      "sha256": "<full sha256 of the archive>",
      "bytes": 46137344,
      "description": "Sony a7S II, 19 frames 4240x2832 JPEG, static tripod, clear sky. The pilot's sequence.",
      "provenance": "Brian Martin, own photographs."
    }
  }
}
```

- **Asset names are content-addressed.** An asset is never replaced under the same name: a changed
  dataset is a new archive with a new name, plus a manifest edit. Old assets stay, so old commits
  stay reproducible.
- **One archive per dataset**, containing a single top-level directory named after the dataset.
  Use `.tar.gz`, because it must unpack with the `tar` available in Git Bash on `windows-2022` as
  well as macOS and Linux. Check that on Windows rather than assuming.

**2. Fetch tool: `test_data/fetch.sh <name>…`** (bash, `curl` + `sha256sum`/`shasum -a 256` + `tar`):

- **Cache directory:** `$STAR_TEST_DATA` if set, else `<repo>/.test-data` (add it to `.gitignore`).
  A dataset unpacks to `<cache>/<name>/`.
- **Idempotent:** skip if `<cache>/<name>/.complete` holds the manifest's sha256. Otherwise
  download to a temp file, verify the sha256, unpack beside it, rename into place, and write
  `.complete` last. An interrupted fetch must never look complete.
- **Exit codes and errors:** non-zero with a clear message on an unknown name, a checksum mismatch
  or a failed download.
- **`--list`** prints each dataset with its size and description.

**3. Placeholders resolve through the manifest at generation time.**

- A `params.json` value of the form `data:<name>` means a dataset. The pilot's
  `"sequence": "test_data/test_a7sii_10"` becomes `"sequence": "data:a7sii_10"`.
- `star-gherkin-gen` reads `test_data/datasets.json` and **fails generation, with file:line**, on a
  `data:` name the manifest doesn't have.
- It also emits, per client, the list of datasets that client's features need: generated, committed,
  one name per line, e.g. `gherkin/generated/datasets-cli.txt`. CI fetches exactly that list, so
  nobody maintains it by hand. That's the trap Preffect's `FEATURE_FILENAMES` fell into.
- Keep the generator's output identical across gherkin 9.0.0 and cucumber-gherkin 42.0.1. The
  `generate-check` job proves it.

**4. Runners: resolve, never download.**

- In all three runners (`CliFeatureRunner.swift`, `GuiFeatureRunner.swift`,
  `DesktopFeatureRunner.kt`), a `data:<name>` value resolves to `<cache>/<name>`. `<cache>` follows
  the fetch tool's rule:
  - cli: `STAR_TEST_DATA` env, else `<repoRoot>/.test-data`
  - gui: `TEST_RUNNER_STAR_TEST_DATA` under xcodebuild
  - desktop: a `star.test.data` system property forwarded by the `gherkinTest` task, like
    `star.repo.root`
- If the directory or its `.complete` is missing, **fail** (never skip) with the exact command to
  run: `test_data/fetch.sh <name>`.
- The existing copy-to-a-fresh-temp-dir step stays. The cache is read-only input.
- Plain paths (relative to the repo, or absolute) keep working, for local experiments.

**5. CI** (`.github/workflows/gherkin.yml`, every leg). Before the test step:

- `actions/cache` on the cache directory, keyed on `hashFiles('test_data/datasets.json',
  'gherkin/generated/datasets-<client>.txt')`
- then `test_data/fetch.sh $(cat gherkin/generated/datasets-<client>.txt)`

A cache hit should make the fetch a no-op. Prove it with the second run's log.

**6. Fold the gui's splash video into the same manifest.**

- `11_30_2024-fx3-aurora-topaz-star.mp4` is a build input, not test data, but it gets the same
  treatment: a manifest entry (checksum-verified) and the same fetch tool.
- Replace the raw `gh release download ci-assets` step in `gherkin.yml` with the fetch tool plus a
  copy or symlink into `gui/videos/`. That step exists so `-StarUITestOpenSequence` runs can build
  the app.
- Leave `cli.yml`'s `macos-signed-release` job alone in this task. It's the release path, and
  changing it can only be checked on a release tag.

### Uploading: this needs Brian

Creating the `test-data` release and uploading assets is a public, outward-facing action. **The
agent can't do it.** The `gh` CLI on this Mac is logged in as `brian-preffect`, which has pull-only
access to this repo, and SSH pushes from an agent session have failed for lack of a loaded key.

So the agent:

1. builds each archive locally, deterministically: sorted entries, fixed mtimes, no owner/group,
   e.g. `tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner` with GNU tar, or the BSD
   equivalent. Rebuilding then gives the same sha256.
2. writes the manifest with the real sha256 and size.
3. stops and gives Brian the exact commands, for example:
   ```bash
   gh release create test-data --repo brianm998/starry_timelapse_airplane_remover --prerelease --title "Test data" --notes "Content-addressed test datasets; see test_data/datasets.json."
   ```
   ```bash
   gh release upload test-data <archive> --repo brianm998/starry_timelapse_airplane_remover
   ```
4. after Brian confirms the upload, verifies every manifest URL anonymously with
   `curl -fsIL <url>` before pushing the workflow change.

Don't try other credentials or hosts to get around this.

### Done for Part 2

- `openAndProcess` runs from `data:a7sii_10` on all six legs and is green.
- Nothing under `gherkin/` or the three runners refers to `test_data/test_a7sii_10` any more.
- On the second CI run the dataset comes from `actions/cache`, and the logs show the fetch skipped.
- A deliberately wrong sha256 in the manifest fails the fetch step loudly. Prove it once on a
  throwaway commit, then revert.
- `gherkin/README.md` and a new short `test_data/README.md` cover:
  - adding a dataset (build the archive, compute the sha, ask Brian to upload, add the manifest
    entry, regenerate)
  - the cache directory and `STAR_TEST_DATA` (worth setting once in Brian's shell profile, so the
    worktrees share one cache)
  - the `data:` param form
- Report back with:
  - per-leg job times
  - archive sizes
  - anything here that turned out wrong (Windows `tar`, xcodebuild env forwarding, cache keys)

## Out of scope (list them in the PR as follow-ups)

- Moving the other readers of `test_data/test_a7sii_10` onto the manifest:
  - `cli/packaging/self-test.sh:35`
  - `star-desktop/packaging/self-test.sh:23`
  - `daemon/Tests/StarDaemonTests/ExportSequenceTests.swift:222`
  - `cli.yml`'s smoke tests

  After that, the directory can leave the tree.
- New datasets: the a7iv/a9 aurora sequences, the moving sequence behind the frame-481/482 bug,
  videos for video import, and `horizon_test_data`/`small_horizon_test_data`, which StarCore's
  `HorizonTests` skip when absent, so CI has never run them. These arrive with the features that
  need them.
- Synthetic sequences with known airplane positions, and downscaled variants.
- Datasets over 2 GiB (S3/R2).
- Collapsing gherkin.yml's duplicated setup into reusable workflows, and the Windows leg's
  MSVC/`stard` build time.
- Any new `.feature` files.
