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

The `@ui` features, the snapshots and the probes of §6.3 are not written yet.
