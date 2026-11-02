@uiMultiChoiceOtherFramesRangeExcludesFrame @ui @mac-gui @desktop
Feature: The multi-choice sheet applied from this frame to the end leaves the frames before it alone

  The rest of E4 of the parity plan, with `uiMultiChoiceOtherFrames` (a feature file holds one scenario, so the range has its own): the sheet's range
  choice "from this frame to the end" applied from frame 1 reaches frame 1 and not frame 0. The frames of the processed sequence (a static sky) share no group positions, so nothing in the other frames
  would move; the step "the processed copy has the outliers of frame 0 copied into frame 1" makes frame 1's groups frame 0's, pixel for pixel, so
  every group of frame 0 has a twin in frame 1, and the multi-choice sheet's apply reaches it. Frames are counted from 0.

  Scenario: Keep from this frame to the end leaves the frame before it alone
    Given a processed copy of the sequence {sequence}
      And the processed copy has the outliers of frame 0 copied into frame 1
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
    Then  "frame.number" says "frame 0"
    When  I choose the menu command "removeAll"
    Then  "status.keep" says "0 will keep"
    When  I press "right"
    Then  "frame.number" says "frame 1"
    When  I choose the menu command "removeAll"
    Then  "status.keep" says "0 will keep"
    When  I click "right.multichoice"
      And I click "outlier.first"
    Then  "multichoice.summary" is shown
    When  I click the label "multi_selection.allAfter"
    Then  "multichoice.summary" is shown
    When  I click "multichoice.apply"
    Then  "multichoice.summary" is not shown
      And "status.keep" stops saying "0 will keep"
    When  I wait 3 seconds
      And I press "left"
    Then  "frame.number" says "frame 0"
      And "status.keep" is still saying "0 will keep"
