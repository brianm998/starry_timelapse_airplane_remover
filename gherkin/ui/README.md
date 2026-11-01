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
  Both runners read it (`GuiFeatureRunner.knownGap`, `DesktopFeatureRunner.knownGap`). It is empty. It held four features for the desktop for a while, which were gaps of the *test host*, not of the app
  (the desktop has the same menu, windows, start screen and recents button, but the Compose test host has no AWT menu bar or window, and cannot start the JavaFX video the start screen embeds); they closed when
  the runner learned to work on what the app draws those from (below). It then held one real difference, the decision-tree menu items, until the owner chose the gui's behaviour. A feature of the gui's that fails on the desktop for a real
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
| `I open the copied sequence without its startup questions` | opens it on the sequence screen (gui: `-StarUITestSkipStartupQuestions YES`, which the seam in `ViewModel` reads; desktop: the view model's `autoMode` hook) |
| `I click "<id>"` | clicks the control with that id |
| `I press "<key>"` | `return`, `escape`, `tab`, `space`, an arrow, or one character, with modifiers before it (`cmd+w`) |
| `I drag around "<id>"` | drags a small box around the element's centre (24 points square in the gui, 48 pixels on the desktop), held a moment first so that it is a drag; what is under the pointer gets it, which for a group's probe (`outlier.first`) is the frame, so the chosen tool acts on the box: the Multi tool opens its area sheet |
| `I command-click "<id>"` | a click with the command key held (control off a Mac): adds a grid cell to the selection (gui: `XCUIElement.perform(withKeyModifiers:)`; desktop: the key held through the key scope around a pointer click) |
| `I right-click "<id>"` | opens the control's context menu, whose items `I click the label "<key>"` then presses (gui: the app's menu items; desktop: the popup's) |
| `I click the label "<key>"` | clicks the control that shows the catalogue's text for the key (the one in a sheet or dialog when one is up, else the last one drawn): for the choices of a picker that has no id of its own (gui: a radio button, button or menu item by its label; desktop: the last enabled control with that text, pressed through its own action) |
| `I wait <n> seconds` | does nothing for that long with the app running: for what shows only after a timer in the app or the daemon has gone off, which no condition can wait for (a frame saved ten seconds after an edit). Not for waiting for the app: every other step does that |
| `I wait for processing to finish` | waits (up to 20 minutes) for a run that has begun: the progress line (`processing.progress`, in the left panel of the edit and scrub screens only) says every frame is complete and the run idle, after it has said running. The feature sees the processing screen come up first, presses Return (Preview) to look away from it, and goes to edit mode, where the line is |
| `I wait for processing to stop` | waits (up to 20 minutes) for the run to be idle, whether or not every frame is complete: for a run that another start put an end to, which leaves the frames it had cleared unfinished. The progress line must stay idle for three seconds, so the moment between a run being stopped and the next one starting is not taken for the end. Like the step above, from edit or scrub mode, after the processing screen has come up |
| `I make the window large` | the gui zooms its main window through the Window menu (it opens at 900 by 450 points, where the grid is one cell tall and its lower rows are not built); the desktop's test window is large already |
| `"<id>" is still saying "<text>"` | the element says it now, with no waiting for it to: for a state that must have been there all along, which `says` would let a frame pass by getting there late |
| `"<id>" stops saying "<text>"` | waits (up to 90 s) until the element says something else: for a count that moves off a value it is known to start on, without the feature pinning the new one |
| `"<id>" is shown` / `is not shown` | the id is in the window (waited for, in both directions) |
| `"<id>" is selected` / `is not selected` | a radio choice (gui: the selected trait; desktop: `selectable`) |
| `"<id>" is on` / `is off` | a switch or check box |
| `"<id>" reads "<key>"` | the control's text is the English catalogue's text for the key (`STAR_LANG=en` in both runners) |
| `"<id>" says "<text>"` | the control's text is exactly that (for a text with a number in it, such as `frame 2`) |
| `I type "<text>" into "<id>"` | clicks the field (which opens a tap-to-edit one), replaces what it holds with the text and leaves it focused |
| `"<id>" holds the number <n:int>` | the first whole number in the control's text is that: `7` in an open field, `merge with 7 static neighbors` in one that is not |
| `"<id>" has the keyboard` / `does not have the keyboard` | the control is the one being typed into (gui: `hasKeyboardFocus`, desktop: `Focused`) |
| `the language is "<code>"` | the run is in that language of the catalogue (default `en`): gui `STAR_LANG`, desktop the `language` preference (the view model applies it when it starts, so an override set before it did is undone); `reads` and the menu steps then use that catalogue; the generator checks the code |
| `a processed copy of the sequence {sequence}` | a copy, in the scratch directory, of the processed sequence the cli made once (`make-processed-fixture.sh`, below), its json files' absolute paths rewritten to the copy |
| `I open the processed copy` | opens it as Load Config does (gui `-StarUITestOpenConfig`, with `-StarUITestProbes YES`; desktop `openConfig`); the reopened sequence says where it left off, which the feature closes (`sequenceprogress.close`) |
| `I confirm closing if it is asked` | presses the red button of the work-in-progress question if it comes up within six seconds; not being asked is fine |
| `the app is started with no sequence` | launches on the start screen |
| `the preferences have <n:int> recent sequences` / `the preferences file lists <n:int> recent sequences` | seeds, and then reads, the recents in the scratch `$HOME`'s preferences file |
| `the preferences file is the fixture "<fixture>"` | puts a file of `gherkin/ui/fixtures/prefs/` (`unreadable`: truncated JSON; `foreignKey`: a key only the desktop writes) in the scratch `$HOME` before the app starts; the generator checks the name |
| `the preferences file is still the fixture "<fixture>"` | the file is those bytes now and stays so for four seconds (longer than the app takes to write one it means to) |
| `the preferences file still has the key "<key>"` | the file parses and has that top-level key |
| `the preferences file has an undecodable copy of the fixture "<fixture>"` | `<prefs file>.undecodable` holds those bytes |
| `I choose the menu command "<command>"` / `the menu command "<command>" is enabled` / `is disabled` | by a `commands.json` id: its menu title and label come from that file and the English catalogue (gui: the menu bar; desktop: the menus as data, see below) |
| `the menu "<menu>" is there` / `is not there` | the menu is in the menu bar, by a `commands.json` menu (`file`, `actions`, `tools`, `window`): its title comes from that file and the catalogue; the generator checks the name |
| `the "<window>" window is open` / `is not open` | `debug` or `outlier` (gui: a window with that title; desktop: the view model's flag `Main.kt` shows the window for) |

The features so far (all pass on both clients): `uiStartupDefaults`, `uiStartupReturnStarts`, `uiStartupHorizonQuestion`, `uiStartupMovingHorizonQuestion`,
`uiStartupNoHorizonSkips`, `uiStartupBackToHorizon`, `uiStartupBackFromRemoval`, `uiRemovalSelectiveChoice`, `uiSettingsFromStartup`, `uiSettingsTabs`,
`uiSettingsProcessNow`, then `uiSecondaryWindowToggles`, `uiSecondaryWindowsNeedASequence`, `uiSequenceWindowsGoWithIt` (M11) and `uiRecentsRemove` (D12), and, on the sequence screen reached without the startup questions, `uiModePickers` (Q8), `uiViewPickerNeedsAnImage` (Q1) and `uiFrameKeys`, and on the same screen the menu's state, `uiMenusNeedASequence`, `uiMenuCommandsIdle`, `uiMenuCommandsWhilePainting` and `uiDecisionTreeCommandsIdle` (M12: Actions and Tools are in the menu bar only while a sequence is open; which items are on with a sequence open and nothing running, and while the horizon painter is open; the gui's rules are the reference, `MenuState` is the desktop's copy and `MenuStateTest` also holds the states a feature cannot reach: the processing screen up, a run going, a video rendering). Then `uiPainterOpensInEditMode` (M7: Paint Reference Horizon from scrub or grid switches to edit) and `uiKeysWhilePainting` (M4: under the painter the arrow keys move the frame and a mode key does nothing), `uiNumberFields` (Q9, P3: a number field commits on Return, puts the old number back on Esc, and gives the keyboard back either way), `uiTranslatedScreen` (I1: in German the startup question, the settings sheet and the pickers read what de.json says), and, from the processed sequence, `uiOutlierClicks` and `uiOutlierClickKeeps` (E1: a click on a group flips its decision, either way, whichever tool is chosen) and `uiDecisionsSurviveClose` (L3: a decision made just before Close is there when the sequence is opened again), and the two that put a preferences file under the app, `uiCorruptPreferences` (M1: a file that does not parse is left as it is and a `.undecodable` copy is kept) and `uiSharedPreferences` (M2: a key the client does not know is still there after it saves; opening a sequence is the save). The settings sheet is reached through the Advanced gear on a startup question, which both clients have, so no seam is needed.

**What the desktop's runner does where the gui has an AWT menu bar, windows and a video.** The desktop's menu bar and secondary windows are AWT, which the Compose test host does not have, so those steps work on what the
app draws them from, and a test holds the drawing to that. The menus are data, `starMenus(app)` (titles, labels, enabled, handler), which `StarMenuBar` draws as the `MenuBar` and nothing else builds; the runner reads it
with `starMenusNow` (on the UI thread, without composing anything) and chooses an item by calling its handler (a disabled item cannot be chosen, as in a menu). A window is open when the flag in the view model that `Main.kt` shows its `Window` for says so, and
`SecondaryWindowsWiringTest` holds `Main.kt` to that. The start screen's JavaFX video is off for a `@ui` feature (`-Dstar.ui.noIntroVideo`, `NO_INTRO_VIDEO_PROPERTY`; the gui has a video too and plays it), the
preferences are the scratch `user.home`'s, and where a list has a control per row (the recents' remove button) a click on the id takes the first.

**Two things about keys on the desktop's test host.** A click on a control with a hover tip (the neighbour field) leaves the tip up, and a tip is a second Compose root; the key step sends the pointer to a corner, which closes it, and then keys the first root, the window's. And a key sent after a number field gave up the keyboard (Return, Esc) did not reach the host's key handler, though the host held the focus (traced: no event arrived; cause not found), so `uiNumberFields` asks `has the keyboard` / `does not have the keyboard` and does not press an arrow after it.

A feature that presses a key (`uiFrameKeys`) runs on the desktop with the window's key handler (`handleGlobalKey`, which `Main.kt` hangs on the `Window`, outside `StarApp`) hosted on an
ancestor of `StarApp` by the runner (`KeyHost`), in the same bubble phase and with the focus on it: the handler is the real one, the host is the test's own.

**A loaded machine can lose a click or a key** sent while a screen is still being put up (seen with a load average of 10 to 14, from other builds): the gui runner waits for a control to be hittable and its frame to stop
moving, and the desktop runner for the Compose clock to be idle, and neither can be sure. A feature that fails once and passes on a rerun, with the same step and nothing changed, is that; the gui runner also ignores
the windows the last run left open (`-ApplePersistenceIgnoreState YES`), which a restored window used to make an order-dependent failure.

**The settings sheet that stayed on "Loading…" (found and fixed).** The desktop's `uiSettingsFromStartup`, `uiSettingsProcessNow` and `uiSettingsTabs` sometimes (1 run in 54 at first, then 4 to 7 in 21) waited out the 90 s on a sheet that never left "Loading…", with the engine's config already in (traced: `getConfig` answered in 6 ms). The sheet's `produceState` wrote its state after the reply, on whichever thread the reply arrived on; a test host's coroutines run where they are resumed, so it was a worker thread, and now and then composition never saw the write (a thread dump of a hang showed `stard` idle and the UI thread drawing; tracing the write made the race vanish). The sheet writes it on the UI thread now (`withContext(Dispatchers.Main)`, which is where the real app resumes it): 21 runs of the three features in a row. If another sheet ever sticks on "Loading…" in a test, look for a `produceState` or `LaunchedEffect` that writes state after a call that resumes on another thread.

Run one with `./gradlew gherkinTest -Pstar.stard.path=$PWD/../daemon/.build/debug/stard --tests '*.uiStartupDefaultsFeature'` in `star-desktop` (one feature
per Gradle run: a second in the same JVM trips over the first one's leftover coroutines) and with `xcodebuild test … -only-testing:starUITests/GeneratedFeatureUITests/testUiStartupDefaultsFeature`
(see `gherkin/README.md`).

**The processed sequence** (`make-processed-fixture.sh`). The outlier-group features start from a sequence that has been processed: processing it inside each feature would take 100 s on the desktop and 12 minutes in the gui, so the cli does it once, selective, no horizon, a static camera, and the runners take a relocated copy. The script keeps it under `STAR_UI_FIXTURES` (default `.test-data/ui-processed`, which git ignores) in a directory named for the sequence and for the cli that made it, so a new cli makes a new one and a second feature of the same run finds the first's (about 180 MB, made in about 90 s once the cli is built). The cli is `STAR_CLI_PATH`, else `cli/.build/release/star`, and the runners ask the script to build it when it is missing (`STAR_CLI_BUILD=1`: `swift build -c release --package-path cli`, six minutes on this Mac). **A CI job that runs these features therefore needs a toolchain that builds the cli**; the gui and desktop legs have not been run in CI with this. One outlier group of the open frame is found by the id `outlier.first`, under `-StarUITestProbes YES` (gui) or `-Dstar.ui.probes` (desktop): the smallest box drawn on the frame, which is the one on top; clicking it is a click on the frame.

Not written yet, from §6.3: the snapshots and the other probes, and the rest of the outlier features (E2 to E6, L6 to L8, L10), and the fixture
`ui_small` (the in-repo `test_data/test_a7sii_10` stands in for it; the processed one is made by the cli, above).

## macOS-only check: the Dock icon brings the desktop's window back (M10)

A `@ui` feature cannot show this: the Compose test host has no AWT windows, so the window the Dock icon reopens does not exist there. `star-desktop/packaging/dock-reopen-check.sh`
runs the packaged app instead, on a Mac, and is not a feature: it is not generated, not in `known-gaps.json` and not in CI.

```
cd star-desktop
./gradlew createDistributable -Pstard=$PWD/../daemon/.build/debug/stard      # a packaged app: `./gradlew run` is a bare `java` with no bundle, which `open -a` cannot address
packaging/dock-reopen-check.sh build/compose/binaries/main/app [work-dir]
```

It starts `Star.app` with no sequence (its `HOME` is in the work dir, so your preferences are not touched), brings it forward as a launch from the Dock does, and prints one line per state:

| line | what it saw |
|---|---|
| `PASS 1/3` | the main window (layer 0, at least 200 by 200) is on screen and titled `Star`, the start screen's title |
| `PASS 2/3` | after a click on the window's red close button (what `onCloseRequest`, `AppViewModel.requestCloseWindow`, answers; there is no work in progress, so no "Close Anyway" question), the process is still running and has no window on screen |
| `PASS 3/3` | after `open -a Star.app` (what a Dock click sends: a reopen event, and the app is raised) the same process has its main window back, titled `Star`; if that brings nothing in 15 s the script tries a bare AppleScript `reopen` and says so |

Exit codes: `0` all three passed; `1` a state failed (`FAIL:` says which, and what was seen: whether the process is running, every on-screen window of it with its size, and the app's last output); `77` skipped,
with `SKIP: <why>` (not a Mac, no display or no GUI session on the console, no `Star.app` in the image, or System Events will not answer or cannot see the window, i.e. Automation or Accessibility is not granted to the terminal or runner).
A skip is not a pass: nothing was looked at. The guard is at the top of the script.

It does not tell the two listeners in `Main.kt` apart: `open -a` raises the app too, so `AppReopenedListener` (the Dock click) and `AppForegroundListener` (the app coming forward) could each have shown the window. The close is the
window's own button, not Cmd-W (that is the menu's Close, `requestCloseSession`). The start screen is known by its title only, and the check starts with no sequence open, so it does not show that a loaded sequence is unloaded by the close
(`MainWindowCloseTest` and `PendingWorkTest` hold the rule). It needs the packaged app to carry a `stard` and ffmpeg (`createDistributable` refuses otherwise), but the window does not depend on the engine.

**Running it somewhere else** needs a macOS runner with a logged-in desktop session (a display, and the user on the console: not ssh, not a headless VM), Automation and Accessibility granted to the shell or runner that runs it,
and the packaged app built first (`createDistributable`, with a built `stard`). System Events answers slowly under load (20 s a call seen here) and the app's
window can take a minute to appear in the accessibility tree, so the script waits up to 120 s for it and a run takes two to four minutes.
