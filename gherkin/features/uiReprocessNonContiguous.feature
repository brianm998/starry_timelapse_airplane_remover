@uiReprocessNonContiguous @ui @mac-gui @desktop
Feature: Re-processing two frames of a selection leaves the frame between them alone

  L6 of the parity plan. In the grid a selection need not be one run of frames: frames 0 and 2 can be selected with 1 left out. Re-Process Outliers
  on that selection runs the outlier stage again for those two frames and for no other (the gui used to clear every frame from the first to the last,
  and so the decisions made on the one between). Frame 1 has every group removed by the user before; after the run, which the processing screen lets
  the user look away from (Preview) while it goes on, it still has them removed. Starts from the processed sequence the cli made once.

  Scenario: Re-process frames 0 and 2, not 1
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I make the window large
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I press "right"
    Then  "frame.number" says "frame 1"
    When  I choose the menu command "removeAll"
    Then  "status.remove" stops saying "0 will remove"
    When  I click "mode.grid"
      And I click "grid.cell.0"
      And I command-click "grid.cell.2"
      And I right-click "grid.cell.2"
      And I click the label "ui.re_process_outliers"
    Then  "processing.modal" is shown
    When  I press "return"
      And I click "mode.edit"
      And I wait for processing to finish
      And I click "mode.grid"
      And I click "grid.cell.1"
      And I click "mode.edit"
    Then  "frame.number" says "frame 1"
      And "status.keep" says "0 will keep"
      And "status.remove" stops saying "0 will remove"
