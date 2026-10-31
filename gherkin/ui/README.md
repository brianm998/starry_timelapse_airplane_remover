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
  Both runners read it (`GuiFeatureRunner.knownGap`, `DesktopFeatureRunner.knownGap`). It lists four features for the desktop. Those are gaps of the *test host*, not of the app: the desktop has the same menu, windows, start screen and recents button, but the
Compose test host cannot reach an AWT menu bar or window, and cannot start the JavaFX video background the start screen embeds. The desktop runner's steps for those say so
(`not reachable in the desktop test host`), the ratchet turns each entry into a failure the day its steps work, and a feature of the gui's that fails on the desktop for a real
difference goes here with that difference as the reason.

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
| `I click "<id>"` | clicks the control with that id |
| `I press "<key>"` | `return`, `escape`, `tab`, `space`, an arrow, or one character, with modifiers before it (`cmd+w`) |
| `"<id>" is shown` / `is not shown` | the id is in the window (waited for, in both directions) |
| `"<id>" is selected` / `is not selected` | a radio choice (gui: the selected trait; desktop: `selectable`) |
| `"<id>" is on` / `is off` | a switch or check box |
| `"<id>" reads "<key>"` | the control's text is the English catalogue's text for the key (`STAR_LANG=en` in both runners) |
| `the app is started with no sequence` | launches on the start screen |
| `the preferences have <n:int> recent sequences` / `the preferences file lists <n:int> recent sequences` | seeds, and then reads, the recents in the scratch `$HOME`'s preferences file |
| `I choose the menu command "<command>"` / `the menu command "<command>" is enabled` / `is disabled` | by a `commands.json` id: its menu title and label come from that file and the English catalogue |
| `the "<window>" window is open` / `is not open` | `debug` or `outlier` |

The features so far (the first eleven pass on both clients; the last four pass on the gui and are known gaps of the desktop's test host): `uiStartupDefaults`, `uiStartupReturnStarts`, `uiStartupHorizonQuestion`, `uiStartupMovingHorizonQuestion`,
`uiStartupNoHorizonSkips`, `uiStartupBackToHorizon`, `uiStartupBackFromRemoval`, `uiRemovalSelectiveChoice`, `uiSettingsFromStartup`, `uiSettingsExpertToggle`,
`uiSettingsProcessNow`, then `uiSecondaryWindowToggles`, `uiSecondaryWindowsNeedASequence`, `uiSequenceWindowsGoWithIt` (M11) and `uiRecentsRemove` (D12). The settings sheet is reached through the Advanced gear on a startup question, which both clients have, so no seam is needed.

Run one with `./gradlew gherkinTest -Pstar.stard.path=$PWD/../daemon/.build/debug/stard --tests '*.uiStartupDefaultsFeature'` in `star-desktop` (one feature
per Gradle run: a second in the same JVM trips over the first one's leftover coroutines) and with `xcodebuild test … -only-testing:starUITests/GeneratedFeatureUITests/testUiStartupDefaultsFeature`
(see `gherkin/README.md`).

Not written yet, from §6.3: the snapshots and probes, `I choose the menu command`, the outlier-group elements, the window steps, and the fixtures
`ui_small` / `ui_small_selective` (the in-repo `test_data/test_a7sii_10` stands in, and these features need no outlier ids).
