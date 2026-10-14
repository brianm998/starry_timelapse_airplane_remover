# Result: Gherkin speed and test data

Implemented on branch `claude/gherkin-speed-test-data-8b2cf1`. **Not pushed, no PR, CI never run**, and the
release assets do not exist yet, so Part 2 cannot go green until Brian uploads them.

## Part 1: release builds (done, measured locally on the iMac Pro, not on macos-15)

- **cli (both OSes):** `swift test -c release -Xswiftc -enable-testing --disable-swift-testing --package-path cli --filter GherkinTests`
  (option B, one release compile). Locally: the XCTest scenario took **~33 s** (CI's debug step was 1332 s); the cold release
  compile plus run took 3 min. Option A was not measured, so "keep the lower job time" was not done as written: B was chosen because
  it is one compile. **Finding:** without `--disable-swift-testing`, `swift test` runs a second Swift Testing pass that starts `star`'s
  `@main` inside the test binary; it rejects `-c release` as star's own `-c` flag and the command exits 1 after the test passes.
  Applied to both cli legs; README command updated.
- **mac gui:** `-configuration Release` overrides the scheme's TestAction (no scheme edit). **Finding:** it also needs
  `ENABLE_TESTABILITY=YES`, because `starTests` does `@testable import Star` and Release builds every test target even under
  `-only-testing`. With both, the XCUITest passed locally in **570 s** (CI's Debug run: 1495 s). The "Point StarDecisionTrees debug at
  release" step is deleted; local Release passed with empty debug dirs, so it was not needed. Ad hoc signing worked. The LaunchAction's
  ASan did not leak in (the build products were `Variant-NoSanitizers`).
- Local test-step times are under 10 minutes; CI times are unknown until a run.

## Part 2: test data (code done; upload and CI proof pending)

- `test_data/datasets.json` (manifest), `test_data/fetch.sh` (cache, sha256 check, atomic `.complete`, `--list`),
  `test_data/build_archive.sh` (deterministic archives, verified: two builds give the same sha256), `test_data/README.md`.
- Generator: `data:<name>` params checked against the manifest (error carries `params.json:line`; tested), writes
  `gherkin/generated/datasets-{cli,mac-gui,desktop}.txt`; manifest is part of the source hash. `params.json` now uses `data:a7sii_10`.
  Regenerated with gherkin 9.0.0 only; `generate-check` (cucumber-gherkin 42.0.1) is unproven.
- Runners (cli, gui, desktop + Gradle `star.test.data` forwarding) resolve `data:` to `<cache>/<name>` and fail with
  `test_data/fetch.sh <name>` if absent. Nothing under `gherkin/` or the runners mentions `test_data/test_a7sii_10` any more.
- `gherkin.yml`: every leg gets `actions/cache` on `.test-data` + `fetch.sh $(cat …)`; mac-gui also fetches `gui_splash_video` and
  copies it into `gui/videos/` (replacing `gh release download ci-assets`); `test_data/**` added to the path triggers.
- Verified locally: fetch via a fake-curl shim (download, unpack, idempotent skip, wrong sha256 fails loudly with exit 1 and leaves
  nothing behind); the cli Gherkin test passed end to end from `data:a7sii_10` in the cache.
- Archive sizes: `a7sii_10-76013afcefe5.tar.gz` 46,406,596 B; `gui_splash_video-35575f903725.tar.gz` 401,935,302 B. Both are in
  `.test-data/upload/` (git-ignored) in this worktree.

## Remaining (needs Brian)

1. Upload (the agent's `gh` is pull-only):
   ```bash
   gh release create test-data --repo brianm998/starry_timelapse_airplane_remover --prerelease --title "Test data" --notes "Content-addressed test datasets; see test_data/datasets.json."
   gh release upload test-data .test-data/upload/a7sii_10-76013afcefe5.tar.gz .test-data/upload/gui_splash_video-35575f903725.tar.gz --repo brianm998/starry_timelapse_airplane_remover
   ```
2. Then verify anonymously (`curl -fsIL <url>` for both manifest URLs), push, open a PR.
3. On CI, still to prove: all six legs green; vacuous-green checks; per-leg job times and the before/after table; second run hits
   `actions/cache` (fetch logs "skipping"); a deliberately wrong sha256 on a throwaway commit fails the fetch step; `generate-check`.
4. Unverified: Git Bash `tar`/`mktemp`/`awk` on windows-2022 (plan said check it); `TEST_RUNNER_STAR_TEST_DATA` forwarding under
   xcodebuild on a runner (the local run used it, but the runner also falls back to `<repo>/.test-data`); the Kotlin runner/Gradle
   change was not compiled or run; the 400 MB splash video now sits in `actions/cache` (counts against the repo's 10 GB).
5. Option A vs B timing on macos-15, and whether either macOS test step is still over 10 minutes.

## Out of scope (follow-ups, as planned)

Other readers of `test_data/test_a7sii_10` (`cli/packaging/self-test.sh`, `star-desktop/packaging/self-test.sh`,
`ExportSequenceTests.swift`, `cli.yml` smoke tests, `kotlin-client.yml`), after which the directory can leave the tree; new datasets;
synthetic/downscaled sequences; >2 GiB datasets; reusable-workflow collapse and Windows build time; new `.feature` files;
`cli.yml`'s `macos-signed-release` job still uses `ci-assets`.
