# star

## Localization

Every user-visible string lives in the catalogue in
`StarCore/Sources/StarCore/Resources/Localizations/` (see `i18n/README.md`).

**English text in a non-English table is not OK.** `en.json` is the only file that may hold
English. Whenever you add or change a key, write a real translation into *every* other
`<code>.json` in the same change — never copy the English value in as a placeholder, and never
leave a new key to be translated "later". At runtime a missing key falls back to English
silently, and a value identical to English looks like a translation to every test, so nobody
will notice but the user who reads that language.

- Translate prose, labels, help text and errors into the table's own language and script.
- Reuse the terminology that table already uses for *frame*, *horizon*, *alignment*,
  *homography*, *neighbor*, etc., so the app reads consistently.
- Keep placeholders (`{0}`, `{1}`) and `\n` breaks; reordering placeholders is fine, adding or
  dropping one is not.
- The only values that may match English are ones that genuinely are the same in that language:
  the product name `star`, international acronyms and format names (GPU, CPU, JPEG, TIFF, fps),
  and pure-placeholder/punctuation strings.
  The `ui.<camelcase>` debug feature names (`ui.maxbrightness`, …) are identifiers and stay
  as they are.
- Check with `i18n/check.py` before finishing. Its "same as English" count per language sits at
  roughly 40 (the exceptions above); if it rises, look at what you added.

## Swift and Kotlin clients change together

The macOS gui (`gui/`, SwiftUI) and the desktop client (`star-desktop/`, Kotlin/Compose) are two
front ends to the same program. A user-facing change to one — a screen's wording, layout,
colours, buttons, estimates, dialogs — is made to the other in the same change, with the same
behaviour and the same catalogue keys, and each side's tests updated. Don't ship one and leave
the other "for later"; if a platform genuinely cannot do something, say so in the change.

## No pull requests for internal work

We don't use PRs for our own changes. PRs are only for work coming in from other people. Normal work is
merged straight into `develop`, and the automated testing (the pipeline's checks and CI) is what makes sure
nothing broke: don't open a PR to get a change reviewed or checked first, and don't wait for one.

## The development pipeline

`pipeline/` is developer tooling (`starpipe`, plans/PIPELINE.md), not part of star. The localization
rule and "Swift and Kotlin clients change together" above are about star's product code and do not
apply to it: don't translate it and don't build a Kotlin twin.

- **Heavy jobs queue in masond**, MASON's daemon, the one arbiter of this Mac: every `swift build|test`, `xcodebuild`, `gradlew`
  and star run goes through `pipeline/bin/starpipe heavy -- <cmd>` (a client of masond: it runs `mason run`) or `mason run` itself.
  Classes: build → `compile`, test → `test-suite`, star runs, UI, Gherkin and unrecognised commands → `--exclusive`. From a
  ticket stage the job ranks as starpipe's (`--pipeline starpipe`, furthest-along ticket first), from a person's session as a
  person's, under a MASON task as that task. If masond cannot be reached the job waits and alerts after 10 minutes; it never runs
  unqueued. starpipe has no queue of its own any more: no `~/.star-pipeline/locks`. MASON's own suites (`.mason/mason.toml`) ask
  for the machine's classes directly and are not wrapped in `starpipe heavy`. `.claude/settings.json` wraps commands for
  interactive sessions automatically (`STARPIPE_NO_WRAP=1` turns that off).
- **Tests never wake this Mac's display or appear on it.** The mac gui's XCUITest runs (`starUITests`) drive the real mouse and
  keyboard and wake the display, so under the default `ui_local = "ci"` (`~/.star-pipeline/config.toml`) they do not run here:
  `heavy.run_job` and the PATH shim `pipeline/shims/xcodebuild` refuse them (exit 69), and a ticket's UI checks are recorded `ci-only`
  (counts as green) and left to GitHub. `"idle"` runs them here once the keyboard and mouse have been idle `ui_idle_s` (which will
  wake a sleeping display), `"always"` runs them unconditionally. `STARPIPE_UI_NOW=1` lets the owner run one; it is ignored for a
  ticket. `test:gui` (`-only-testing:starTests`) still runs here, unseen: `StarMain` hosts it in a background-only app with no windows.
  Never give it `ui=True`: that wraps it in `caffeinate -d -u`, and `-u` turns a sleeping display on.
- **To stop all automated testing at once: `pipeline/bin/starpipe freeze`** (`thaw` lets go). It is MASON-backed: it runs
  `mason pause --mode all` and holds `mason hold --exclusive --pipeline starpipe --label freeze`, so MASON's tasks, the daemon,
  the agents in ticket worktrees and wrapped session commands all wait in masond's queue. It does not stop a run already
  going: kill that first.
- **Model sessions are limited by MASON**: each starpipe session holds `llm:claude` (`mason hold`) for its life, and the count is
  MASON's (`mason resources limit llm:claude N`). starpipe has no `max_llm_sessions` or CPU gate; `starpipe limits` says so.
- `pipeline/bin/starpipe check --explain` says which builds and tests a change needs;
  `starpipe check` runs them and proves each from its own output.
- **File every new star ticket in MASON, never with starpipe.** Don't run `starpipe ticket new`, and don't use the
  file-tickets skill to file: it still files through starpipe. The owner approves the task list in conversation
  first, as before. Then file each task with
  `~/.config/mason/bin/mason task add "<title>" --project star --body-file <file>`, adding `--after <task ids>` for
  tasks that must land first. `mason help filing` is the reference. MASON's configuration is `.mason/` (pipeline
  tooling, like `pipeline/`: no translation, no Kotlin twin).
- **Every ticket you file is already a plan**, so MASON skips exploring: the agent filing the ticket *is* the
  exploration agent. Open the files you name, settle the approach, and write into the body the files to change, how,
  and an `## Acceptance criteria` section (the "Carrying a plan" format in `.claude/skills/file-tickets/SKILL.md`
  still works). Pass `--explored` once the plan is settled. Without it, MASON's clarity check explores any body that
  names a file not yet on the base branch, unless that file is marked `(new)`. A guessed plan is worse than none:
  leave the flag off when you haven't explored the code.
- starpipe still runs until the switch. It claims only issues labelled `pipeline`, MASON claims only `mason`, and an
  issue never carries both. To move a starpipe ticket to MASON: `starpipe cancel <n>`, swap `pipeline` and any
  `pipe:*` labels for `mason`, then approve the imported task with `mason task approve <id>`. GitHub's "blocked by"
  links carry over.

## This machine cannot run the GPU median merge

The GPU version of the median merge logic (`Config.useGPUForMerge`, the Metal merge path) crashes
this Mac roughly 60% of the time or more. It can get through part of a run, then the window
service is locked out and stops responding, and the machine has to be recovered.

**Whenever a test (or any star run) is executed on this machine, ALWAYS use the CPU version of the
median merge logic**: set `STAR_USE_GPU_FOR_MERGE=0` in the environment (also `false`, `no`,
`off`). `ImageAligner` and `Config` honour it for every caller, whatever `config.json` or a test's own
setup says (`GPUCapability.mergeForcedOff`); the default is otherwise on whenever a GPU is detected.
(`~/.star.userprefs.json` is the gui's own preferences and does not do this; the cli ignores it.) Don't run GPU merge
tests or GPU-vs-CPU comparisons here; leave those to CI or another machine.

## Building and testing in a worktree

- **Link the gitignored artifacts first**: run `.mason/scripts/link-artifacts.sh` in the worktree
  (OpenCV, StarDecisionTrees, `gui/videos`, `external_binaries/bin`). Without them, builds fail with
  errors that look like code breakage: `'opencv2/core.hpp' file not found`, `Unable to find module
  dependency: 'StarDecisionTrees'`, or a late `lstat(.../gui/videos/...)` / `lstat(.../ffmpeg)` after
  every Swift file has already compiled. `gui/videos` is the one link `git status` shows (the
  `.gitignore` entry has a trailing slash), so don't commit it.
- **gui**: `xcodebuild -project gui/star.xcodeproj -scheme star -configuration Debug
  CODE_SIGNING_ALLOWED=NO build`. Always `-scheme star`, never `-target Star`: the target skips the
  scheme's package graph and fails with `Unable to find module dependency: 'logging'`, and it leaves
  `build/` dirs behind. Leave out `-destination`. The app module is `Star`
  (`@testable import Star`).
- **cli**: build with SwiftPM (`cd cli && swift build`), which is what `cli/build-optimized` runs.
  `cli/star.xcodeproj` can hit an `ld` assertion (`dylibToOrdinal`) even at a clean HEAD, so don't
  bisect your own edits when you see it.
- **async XCTest**: `XCTAssertEqual(await x, y)` doesn't compile (the arguments are non-async
  autoclosures). Put each `await` in a local first.

## Adding or removing a `Config` property

One property lives in seven places, and only the last is caught by a compiler:

1. `StarCore/.../Config.swift`: the declaration **and** its `decodeIfPresent` line in the
   hand-written `init(from:)`.
2. `StarCore/.../ArtifactInputs.swift`: stage input records, including comments naming settings
   they leave out.
3. `gui/star/`: `ImageSequenceViewModel` (property and its assignment in the config init),
   `FocusedField` (text fields only), `ProcessingSettingsView` (view, state flag,
   `addSpacer`/show-all/hide-all, grid row).
4. `daemon/Sources/stard/Mapping.swift`: two lines (Config→proto, proto→Config).
5. Both `star.proto` copies (`daemon/proto/`, `star-desktop/proto/`), byte-identical apart from the
   `option java_*` lines. Retire a field with `reserved <n>;` plus a comment. Then run
   `daemon/regen-proto.sh`.
6. The Kotlin `ProcessingSettingsDialog.kt` row (plus its `FIELD_HELP` entry).
7. The `ui.` (and `setting_help.`) keys in all 22 catalogues.

A new cli flag also goes in `ConfigOverrides` and `ConfigOverridesTests.everyFlag`. To prove the
change, run all four: `cd StarCore && swift build && swift test --filter ConfigRoundTrip`,
`cd daemon && swift build`, the gui build above, and
`cd star-desktop && ./gradlew checkProtoSync compileKotlin`.

## Editing the localization tables

The tables are in append order, not sorted. Don't use `i18n/check.py --install`: it re-sorts and
rewrites all 22 files. Load each table with `json.load`, add or delete keys, and write it back with
`json.dumps(t, indent=2, ensure_ascii=False) + "\n"`, which round-trips byte for byte. Then run
`python3 i18n/check.py` (read-only).

## Measuring performance

On this machine a single end-to-end run proves nothing: two identical 20-frame runs took 321 s and
413 s, because other apps hold tens of GB resident and swap is full. Time the function itself, in
one process, min-of-K, on real frames, and check a run's peak compressor size before trusting its
wall clock (above ~10 GB, the run is an artifact). Output equivalence still needs a full run.

When a mutation survives a header-only kernel harness, check the include order first: the scratch
copy of the header has to come first on `-I`, otherwise the real header wins and every mutation
passes.

The OpenCV 4.12.0 source is in the main checkout at `opencv/opencv/` (worktrees don't have it).
Read `modules/imgproc/src/imgwarp.cpp` and friends before you guess at a rounding rule.

## Pipeline code

- Run `uv run ruff check` in `pipeline/` before committing straight to `develop`; the pr-gate's
  `static` job runs ruff, pyright and pytest there.
- Pipeline worktrees can't `git fetch` (no SSH key for `origin`), but the daemon keeps
  `origin/develop` current over https. When you answer a stage agent, tell it
  "`git merge origin/develop` (no fetch)".
- Before `starpipe self-update`, compare `develop` with `origin/develop`. If local is ahead, pass
  `--ref develop`, or the runtime is built from the older origin.
