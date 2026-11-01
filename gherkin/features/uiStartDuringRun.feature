@uiStartDuringRun @ui @mac-gui @desktop
Feature: A start while a run is going stops that run and takes its place

  L8 of the parity plan, settled by the owner (D: supersede). Re-Process Everything on frames 0 and 1 starts a run, and while it goes on (the
  processing screen lets the user look away from it, Preview) Re-Process Outliers on frame 2 asks for another. The second takes the first's place:
  the first is stopped, so frames 0 and 1, which it had cleared, are left unfinished, and frame 2 is run, so it has the decision tree's first answer
  where it had none decided (the frames the cli made have no group decided). The desktop used to answer the second start with success and do
  nothing, and frame 2 stayed as it was. Starts from the processed sequence the cli made once.

  Scenario: Re-process outliers of frame 2 during a run over frames 0 and 1
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I make the window large
      And I click "sequenceprogress.close"
      And I click "mode.grid"
      And I click "grid.cell.0"
      And I command-click "grid.cell.1"
      And I right-click "grid.cell.1"
      And I click the label "ui.re_process_everything"
    Then  "processing.modal" is shown
    When  I press "return"
      And I click "mode.grid"
      And I click "grid.cell.2"
      And I right-click "grid.cell.2"
      And I click the label "ui.re_process_outliers"
    Then  "processing.modal" is shown
    When  I press "return"
      And I click "mode.edit"
      And I wait for processing to stop
      And I click "mode.grid"
      And I click "grid.cell.2"
      And I click "mode.edit"
    Then  "frame.number" says "frame 2"
      And "status.keep" stops saying "0 will keep"
    When  I click "mode.grid"
      And I click "grid.cell.0"
      And I click "mode.edit"
    Then  "frame.number" says "frame 0"
      And "status.state" stops saying "frame is complete"
