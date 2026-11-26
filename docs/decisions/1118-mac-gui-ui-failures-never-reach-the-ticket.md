# 1118: mac gui ui red: the failed features never reach the ticket

Run 45669523915 (`Gherkin/mac gui (macos-15) · ui`, commit 1e887c847) is red with 4 failures out of 67. The ticket cannot
say which. MASON's CI watch tails the **first** failed step, which is the xcodebuild step ("Run the Gherkin features in
Star.app (XCUITest)"), and its tail holds only the suite totals and `** TEST FAILED **`. The names are printed by later
steps ("Prove the scenarios ran", "Failure evidence"), so the reordering of decision 1043 never reached the ticket.

Decision: the failing xcodebuild step now ends with a summary. An `EXIT` trap, which covers both the unretried failure and
a failed retry, runs `gherkin/summarize-xctest-failures.sh gherkin-gui.log`: per failed test its failure line and the
runner's click evidence (#1103), and on the very last line `FAILED UI TESTS (N): ...`. The step's exit status, the retry,
the prove step and the evidence step are unchanged. smoke-macos is unchanged: its gui step is continue-on-error and is not
the failed step. CI tooling only: no localization and no Kotlin change.

**The 4 red UI features are not identified and not fixed.** The xcresult and the full log could not be read offline (as in
decisions 0511, 0601, 1043 and 1060). #1103's outlier-click change is in the failing commit, but whether the
`uiOutlierClick*` features are among the 4 is unknown. No product fix was guessed.

Next step: read the next red run's xcodebuild step tail, or run 45669523915's `gherkin-gui-shard-ui-xcresult` artifact,
then fix the named features. If `uiOutlierClick*` are still among them, decision 1060's hypothesis is disproved.
