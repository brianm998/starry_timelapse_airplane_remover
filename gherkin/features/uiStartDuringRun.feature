@uiStartDuringRun @ui @mac-gui @desktop
Feature: A start while a run is going stops that run and takes its place

  L8 of the parity plan, settled by the owner (D: supersede). Re-Process Everything on frames 0, 1, 3, 4 and 5 starts a run, and while it goes on
  (the processing screen lets the user look away from it, Preview) Re-Process Outliers on frame 2 asks for another. The second takes the first's
  place: the first is stopped, so the last frame it had cleared, frame 5, is left unfinished, and frame 2 is run, so it has the decision tree's first
  answer where it had none decided (the frames the cli made have no group decided). The desktop used to answer the second start with success and do
  nothing, and frame 2 stayed as it was. Starts from the processed sequence the cli made once.

  The first run is five frames long, and the check is on its last frame, because the clients differ in how long the second start takes to arrive:
  the desktop's steps are milliseconds apart, the gui's are seconds (the macos-15 runner needed 18 s from one start to the other), and a run of two
  frames was finished by then, frame 0 complete, with nothing left to stop. Frame 5 comes last, so it is the one still going.

  Scenario: Re-process outliers of frame 2 during a run over frames 0, 1, 3, 4 and 5
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I make the window large
      And I click "sequenceprogress.close"
      And I click "mode.grid"
      And I click "grid.cell.0"
      And I command-click "grid.cell.1"
      And I command-click "grid.cell.3"
      And I command-click "grid.cell.4"
      And I command-click "grid.cell.5"
      And I right-click "grid.cell.5"
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
      And I click "grid.cell.5"
      And I click "mode.edit"
    Then  "frame.number" says "frame 5"
      And "status.state" stops saying "frame is complete"
