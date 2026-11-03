@uiFindOutliersInline @ui @mac-gui @desktop
Feature: Find Outliers for this frame works on the frame, with no processing screen

  L7 of the parity plan, settled by the owner (D6). Actions, Find Outliers for This Frame finds the groups of the current frame again and applies the
  decision tree to it, there and then: no processing screen comes up and the frame stays complete. The desktop used to run the whole graph with
  the processing screen. The processed frame starts with groups nobody has decided (selective leaves them to the user), so once the tree has decided
  them the count lines are no longer both none.

  Scenario: Find the outliers of the current frame again
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
    Then  "status.remove" says "0 will remove"
      And "status.keep" says "0 will keep"
    When  I choose the menu command "findOutliersCurrentFrame"
    Then  "status.keep" stops saying "0 will keep"
      And "processing.modal" is not shown
      And "status.state" says "frame is complete"
