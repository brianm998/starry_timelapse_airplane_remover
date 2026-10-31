# gherkin/ui

The shared expectations for the macOS gui and the desktop client (see `plans/GUI_CLIENT_PARITY_PLAN.md`, §6).

* `commands.json` — the menu commands both clients offer, by the catalogue key of their label. Layer 0 of the plan: each client has a
  unit test (`CommandTableTests` in `gui/starTests`, `CommandTableTest` in `star-desktop/src/test`) that reads this file and checks its
  own menu code uses every key, so a command added to one client only is a failing test in the other. `knownGaps` lists, per client,
  what that client does not offer yet and why; an entry that is no longer true fails the test, so it has to be removed.

* `ids.json` — the identifiers a UI step may use (`accessibilityIdentifier` in the gui, `testTag` in the desktop client). `IdRegistryTests` and
  `IdRegistryTest` scan each client's source: every id both carry is in `ids`, every id one client lacks is in that client's `knownGaps`
  with the reason, and an id found that is in neither list, or a gap that has been closed, fails. A control added on one side only is
  therefore a failing test until the other side has it or the gap is written down.

* `vectors/` — small tables of expected answers that both clients are held to, for the logic one of them had to copy by hand (the desktop
  copies StarCore's), or that one of them hides inside a view. Each file says in its `comment` what it pins; each has a test on both sides.

  | file | what it pins | gui / StarCore test | desktop test |
  |---|---|---|---|
  | `constants.json` | disk-space ratio, keypoint divisor choices, custom frame rate rule, playback speeds, the clean method choice and its texts | `SharedConstantsTests` | `SharedConstantsTest` |
  | `processingHeadline.json` | the processing screen's headline, overall and duration texts (record with `TEST_RUNNER_STAR_VECTORS_RECORD=1`) | `ProcessingHeadlineVectorsTests` | `ProcessingHeadlineVectorsTest` |
  | `stepRates.json` | the "about N left" per step | StarCore `StepRateVectorTests` | `StepRateVectorTest` |
  | `byteFormat.json` | a byte count as a user reads it | StarCore `ByteFormattingTests` | `SharedConstantsTest` |
  | `outlierColumns.json` | the outlier table's columns, order, defaults and header keys | `OutlierColumnsTests` | `OutlierColumnsTest` |
  | `clickRules.json` | what a click on an outlier group does (the decision it leaves; apply the tool or open the multi-choice sheet) | `ClickRuleTests` | `ClickRulesVectorTest` |
  | `startScreen.json` | the start screen's controls, in order, with their labels and hover texts | `StartScreenTests` | `StartScreenTest` |

  A vector that changes on purpose is changed in the same commit as both clients. Gradle's `test` task declares `gherkin/ui` and the
  catalogue as inputs, so a changed file reruns the desktop tests; an Xcode run reads them from the source tree.

* `known-gaps.json` — the parity backlog. A `@ui` feature that fails on a client where it is listed here passes, and says `KNOWN GAP`; one that
  fails where it is not listed fails; one that is listed and now passes fails until the entry is removed. `{"gaps": {"<feature>": {"mac-gui": "<why>", "desktop": "<why>"}}}`.
  Both runners read it (`GuiFeatureRunner.knownGap`, `DesktopFeatureRunner.knownGap`). It is empty now. It held four features for the desktop for a while, which were gaps of the *test host*, not of the app
  (the desktop has the same menu, windows, start screen and recents button, but the Compose test host has no AWT menu bar or window, and cannot start the JavaFX video the start screen embeds); they closed when
  the runner learned to work on what the app draws those from (below). A feature of the gui's that fails on the desktop for a real difference goes here with that difference as the reason.

## The `@ui` features

`gherkin/features/ui*.feature`, run by the same two runners as the processing features (`GuiFeatureRunner` with XCUITest, `DesktopFeatureRunner` with
the Compose test host over a real `stard`). A `@ui` feature carries `@mac-gui` and `@desktop` both, never `@cli`, and needs no settings steps or
sequence of its own; `@ui-mac-gui-only` or `@ui-desktop-only` (with `@ui`, and the reason in the text under the `Feature:` line) is the way to
say that one client is deliberate. The generator checks all of that, and that every `"<id>"` a step names is in `ids.json` and every `"<key>"` of `reads` is in
the English catalogue, so a feature cannot name a control nobody has.

**Rules** (plan §6.1). A runner may differ from the other in how it clicks, types and waits, never in what the user does. A step asserts what
the user can see (an element by its id) or what lands on disk. Features are short, and one is one launch of the app.

**Inline arguments.** A step in `steps.json` can hold `"<name>"` (a double-quoted string in the feature) or `<name:int>` (a bare integer):
`I click "<id>"` matches `I click "startup.horizon.no"`. The generated `Step` carries `args` (Swift) / `args` (Kotlin), in order. `{placeholder}`s
are different: they stay literal in the feature and the runner supplies their values.

**The vocabulary so far** (`gherkin/steps.json`; ids are those of `ids.json`):

| step | does |
|---|---|
| `a fresh copy of the sequence {sequence}` | copies it, as `I open the sequence` does |
| `I open the copied sequence` | opens it, and stops at the first startup question |
| `I open the copied sequence without its startup questions` | opens it on the sequence screen (gui: `-StarUITestSkipStartupQuestions YES`, which the seam in `ViewModel` reads; desktop: the view model's `autoMode` hook) |
| `I click "<id>"` | clicks the control with that id |
| `I press "<key>"` | `return`, `escape`, `tab`, `space`, an arrow, or one character, with modifiers before it (`cmd+w`) |
| `"<id>" is shown` / `is not shown` | the id is in the window (waited for, in both directions) |
| `"<id>" is selected` / `is not selected` | a radio choice (gui: the selected trait; desktop: `selectable`) |
| `"<id>" is on` / `is off` | a switch or check box |
| `"<id>" reads "<key>"` | the control's text is the English catalogue's text for the key (`STAR_LANG=en` in both runners) |
| `"<id>" says "<text>"` | the control's text is exactly that (for a text with a number in it, such as `frame 2`) |
| `the app is started with no sequence` | launches on the start screen |
| `the preferences have <n:int> recent sequences` / `the preferences file lists <n:int> recent sequences` | seeds, and then reads, the recents in the scratch `$HOME`'s preferences file |
| `I choose the menu command "<command>"` / `the menu command "<command>" is enabled` / `is disabled` | by a `commands.json` id: its menu title and label come from that file and the English catalogue (gui: the menu bar; desktop: the menus as data, see below) |
| `the "<window>" window is open` / `is not open` | `debug` or `outlier` (gui: a window with that title; desktop: the view model's flag `Main.kt` shows the window for) |

The features so far (all eighteen pass on both clients): `uiStartupDefaults`, `uiStartupReturnStarts`, `uiStartupHorizonQuestion`, `uiStartupMovingHorizonQuestion`,
`uiStartupNoHorizonSkips`, `uiStartupBackToHorizon`, `uiStartupBackFromRemoval`, `uiRemovalSelectiveChoice`, `uiSettingsFromStartup`, `uiSettingsTabs`,
`uiSettingsProcessNow`, then `uiSecondaryWindowToggles`, `uiSecondaryWindowsNeedASequence`, `uiSequenceWindowsGoWithIt` (M11) and `uiRecentsRemove` (D12), and, on the sequence screen reached without the startup questions, `uiModePickers` (Q8), `uiViewPickerNeedsAnImage` (Q1) and `uiFrameKeys`. The settings sheet is reached through the Advanced gear on a startup question, which both clients have, so no seam is needed.

**What the desktop's runner does where the gui has an AWT menu bar, windows and a video.** The desktop's menu bar and secondary windows are AWT, which the Compose test host does not have, so those steps work on what the
app draws them from, and a test holds the drawing to that. The menus are data, `starMenus(app)` (titles, labels, enabled, handler), which `StarMenuBar` draws as the `MenuBar` and nothing else builds; the runner reads it
with `starMenusNow` (on the UI thread, without composing anything) and chooses an item by calling its handler (a disabled item cannot be chosen, as in a menu). A window is open when the flag in the view model that `Main.kt` shows its `Window` for says so, and
`SecondaryWindowsWiringTest` holds `Main.kt` to that. The start screen's JavaFX video is off for a `@ui` feature (`-Dstar.ui.noIntroVideo`, `NO_INTRO_VIDEO_PROPERTY`; the gui has a video too and plays it), the
preferences are the scratch `user.home`'s, and where a list has a control per row (the recents' remove button) a click on the id takes the first.

A feature that presses a key (`uiFrameKeys`) runs on the desktop with the window's key handler (`handleGlobalKey`, which `Main.kt` hangs on the `Window`, outside `StarApp`) hosted on an
ancestor of `StarApp` by the runner (`KeyHost`), in the same bubble phase and with the focus on it: the handler is the real one, the host is the test's own.

**A loaded machine can lose a click or a key** sent while a screen is still being put up (seen with a load average of 10 to 14, from other builds): the gui runner waits for a control to be hittable and its frame to stop
moving, and the desktop runner for the Compose clock to be idle, and neither can be sure. A feature that fails once and passes on a rerun, with the same step and nothing changed, is that; the gui runner also ignores
the windows the last run left open (`-ApplePersistenceIgnoreState YES`), which a restored window used to make an order-dependent failure.

**One rare flake that is not a lost click** (desktop `uiSettingsFromStartup`, and so possibly the other two features that open the settings sheet): after the click on the Advanced gear the sheet stays on "Loading…" until the 90 s timeout: 1 run in 54 as the runner is now (and 5 in 41 while the runner also composed the menus, which it no longer does). Caught once with a thread dump and a `sample`: `stard` was idle (no request pending, every thread waiting), the client's reader was waiting for a frame, and the UI thread was busy drawing frames in `waitUntil`; the sheet's `getConfig()` never completed and never failed, and the cause is not found. A rerun passes. If it becomes common, sample `stard` and `jstack` the test JVM while it hangs (the `STEP:` line is the last thing in the log).

Run one with `./gradlew gherkinTest -Pstar.stard.path=$PWD/../daemon/.build/debug/stard --tests '*.uiStartupDefaultsFeature'` in `star-desktop` (one feature
per Gradle run: a second in the same JVM trips over the first one's leftover coroutines) and with `xcodebuild test … -only-testing:starUITests/GeneratedFeatureUITests/testUiStartupDefaultsFeature`
(see `gherkin/README.md`).

Not written yet, from §6.3: the snapshots and probes, the outlier-group elements, and the fixtures
`ui_small` / `ui_small_selective` (the in-repo `test_data/test_a7sii_10` stands in, and these features need no outlier ids).
