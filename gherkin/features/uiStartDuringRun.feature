@uiStartDuringRun @ui @mac-gui @desktop
Feature: A start while a run is going stops that run and takes its place

  L8 of the parity plan, settled by the owner (D: supersede). Re-Process Everything on frames 0, 1 and 3 starts a run over 0 to 3 (frame 2, in
  between, is not cleared, so it is left alone), and while it goes on (the processing screen lets the user look away from it, Preview)
  Re-Process Outliers on frame 2 asks for another. The second takes the first's place: the first is stopped, so frame 3, which it had cleared and is
  the last it would have reached, is left unfinished, and frame 2 is run, so it has the decision tree's first answer where it had none decided (the
  frames the cli made have no group decided). The desktop used to answer the second start with success and do nothing, and frame 2 stayed as it was.
  Frame 3 is the one checked, not frame 0: the first frame of a run can be finished before the feature's second start, which on a slow machine
  comes many seconds after the first (frame 0 read "frame is complete" on the hosted macOS runner), and then a stopped run and one that was let
  finish look the same. Starts from the processed sequence the cli made once.

  Scenario: Re-process outliers of frame 2 during a run over frames 0, 1 and 3
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I make the window large
      And I click "sequenceprogress.close"
      And I click "mode.grid"
      And I click "grid.cell.0"
      And I command-click "grid.cell.1"
      And I command-click "grid.cell.3"
      And I right-click "grid.cell.3"
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
      And I click "grid.cell.3"
      And I click "mode.edit"
    Then  "frame.number" says "frame 3"
      And "status.state" stops saying "frame is complete"
