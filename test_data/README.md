# test_data

Out-of-repo datasets, listed in `datasets.json` and hosted as assets of the `test-data` GitHub Release
(`brianm998/starry_timelapse_airplane_remover`, public, each asset < 2 GiB). `test_a7sii_10/` is the one
dataset still committed in the tree; the Gherkin features no longer use it, other things still do
(`cli/packaging/self-test.sh`, `star-desktop/packaging/self-test.sh`, `ExportSequenceTests`, `cli.yml`'s smoke tests).

```bash
test_data/fetch.sh --list           # what exists, with sizes
test_data/fetch.sh a7sii_10         # fetch + verify + unpack into the cache
```

## The cache

`$STAR_TEST_DATA` if set, else `<repo>/.test-data` (git-ignored). A dataset unpacks to `<cache>/<name>/` and is
complete only when `<cache>/<name>/.complete` holds the manifest's sha256 (written last, so an interrupted fetch
never looks complete). `fetch.sh` is idempotent. Put `export STAR_TEST_DATA=$HOME/.star-test-data` in your shell
profile once and every worktree shares one cache. Under xcodebuild the gui tests read it from
`TEST_RUNNER_STAR_TEST_DATA`; the desktop `gherkinTest` task forwards it as `-Dstar.test.data`.

## Using a dataset from a feature

A `params.json` value of the form `data:<name>` is a dataset: `"sequence": "data:a7sii_10"`. The generator checks
the name against `datasets.json` (failing with `params.json:line`) and writes `gherkin/generated/datasets-<client>.txt`,
the datasets each client's features need. CI fetches exactly that list. The runners resolve `data:<name>` to
`<cache>/<name>` and **fail**, never skip, with `test_data/fetch.sh <name>` if it is not fetched. They still copy the
dataset to a fresh temp dir first; the cache is read-only input. Plain paths keep working.

## Adding a dataset

1. Build the archive (deterministic: same files give the same sha256):
   `test_data/build_archive.sh <name> <dir-of-frames> [out-dir]`. It prints the asset name
   (`<name>-<first 12 hex of sha256>.tar.gz`), the sha256 and the size.
2. Ask Brian to upload it (the agent's `gh` login is pull-only):
   ```bash
   gh release upload test-data <asset> --repo brianm998/starry_timelapse_airplane_remover
   ```
   Assets are content-addressed and **never replaced under the same name**: a changed dataset is a new archive, a
   new name and a manifest edit. Old assets stay, so old commits stay reproducible.
3. Add the entry to `datasets.json` (`asset`, `sha256`, `bytes`, `description`, `provenance`), one field per
   line: `fetch.sh` reads the file with awk, not a JSON parser.
4. Verify anonymously: `curl -fsIL https://github.com/brianm998/starry_timelapse_airplane_remover/releases/download/test-data/<asset>`.
5. Use it as `data:<name>` in `gherkin/params.json`, then `gherkin/generate.sh` and commit the output.

`gui_splash_video` is not test data but a build input of `Star.app`; it uses the same manifest so CI can fetch it
checksum-verified (the release path in `cli.yml` still uses the `ci-assets` release).
