@uiUpdateSettingsMidRun @ui @mac-gui @desktop
Feature: Changing a setting during a run and choosing Process Now restarts it, and the render question belongs to a run Process All started

  P4 and P11 of the parity plan. A re-process from the grid starts a run that is not Process All, so it has no end-of-run render question. While it goes on
  (Preview) a setting is changed on a processed sequence, so the button reads Update; Update, then No (keep the finished frames), stops the run and asks the
  render question again, as Process All does, and the answer starts the run over. That run is the one Process All started, so its end asks whether to
  render a video; the first run, which was stopped, ended with no question. The feature looks for a question at the two points the stopped run could have raised one (once the pre-render question is up, and once the restart's screen is);
  a question after the first run's natural end cannot be looked for, because the restart stops that run. `AppViewModel` cannot be built in a test, so this had only source scans before.
  The post-render prompt covers the progress line, so the feature does not wait for processing to finish after it, and presses no key after the restart:
  Return then would be Render Now if the prompt had come up. The first run has to still be going when Update is clicked, which `cancelProcessing` being enabled shows. On
  frame 0 alone it was over in 9 s, before Update; on frames 0 to 7 it was over in 38 s on the hosted Windows runner, where the window is slow while the engine
  has every core and the steps after the run began took longer than that (a keypress alone took 13 s). So the setting is changed before the run, where the window is quick
  (Dismiss applies it, and the frames on disk, which the run is only partly rebuilding, still do not have it, so Update still asks), the run is over frames 0 to 17 (the first cell, then shift-click on the one before the last, rather than a click for each; a run
  of the whole sequence takes the settings baseline anew, L11, and Update would then have nothing to ask), and only the menu, Update and No come between its start and the check. Starts from the processed sequence the cli made once.

  Scenario: Update then No over a live run restarts it and the render question comes at the end of the restart
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I make the window large
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I choose the menu command "processingSettings"
      And I click "settings.tab.alignment"
      And I type "50" into "settings.alignment.maxkeypoints"
      And I press "return"
      And I click "settings.dismiss"
      And I click "mode.grid"
      And I click "grid.cell.0"
      And I shift-click "grid.cell.17"
      And I right-click "grid.cell.17"
      And I click the label "ui.re_process_everything"
    Then  "processing.modal" is shown
    When  I press "return"
    Then  "processing.modal" is not shown
    When  I click "mode.edit"
      And I choose the menu command "processingSettings"
    Then  the menu command "cancelProcessing" is enabled
    When  I click the label "ui.update"
      And I click the label "ui.no"
    Then  "prompt.pre.no" is shown
      And "prompt.post.cancel" is not shown
    When  I click "prompt.pre.no"
    Then  "processing.modal" is shown
      And "prompt.post.cancel" is not shown
    Then  "prompt.post.cancel" is shown
