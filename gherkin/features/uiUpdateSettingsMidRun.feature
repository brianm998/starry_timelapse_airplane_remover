@uiUpdateSettingsMidRun @ui @mac-gui @desktop
Feature: Changing a setting during a run and choosing Process Now restarts it, and the render question belongs to a run Process All started

  P4 and P11 of the parity plan. A re-process from the grid starts a run that is not Process All, so it has no end-of-run render question. While it goes on
  (Preview) a setting is changed on a processed sequence, so the button reads Update; Update, then No (keep the finished frames), stops the run and asks the
  render question again, as Process All does, and the answer starts the run over. That run is the one Process All started, so its end asks whether to
  render a video; the first run, which was stopped, ended with no question. The feature looks for a question at the two points the stopped run could have raised one (once the pre-render question is up, and once the restart's screen is);
  a question after the first run's natural end cannot be looked for, because the restart stops that run. `AppViewModel` cannot be built in a test, so this had only source scans before.
  The post-render prompt covers the progress line, so the feature does not wait for processing to finish after it. Starts from the processed sequence the
  cli made once.

  Scenario: Update then No over a live run restarts it and the render question comes at the end of the restart
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I make the window large
      And I click "sequenceprogress.close"
      And I click "mode.grid"
      And I click "grid.cell.0"
      And I right-click "grid.cell.0"
      And I click the label "ui.re_process_everything"
    Then  "processing.modal" is shown
    When  I press "return"
    Then  "processing.modal" is not shown
    When  I click "mode.edit"
      And I choose the menu command "processingSettings"
      And I click "settings.tab.alignment"
      And I type "50" into "settings.alignment.maxkeypoints"
      And I press "return"
      And I click the label "ui.update"
      And I click the label "ui.no"
    Then  "prompt.pre.no" is shown
      And "prompt.post.cancel" is not shown
    When  I click "prompt.pre.no"
    Then  "processing.modal" is shown
      And "prompt.post.cancel" is not shown
    When  I press "return"
    Then  "prompt.post.cancel" is shown
