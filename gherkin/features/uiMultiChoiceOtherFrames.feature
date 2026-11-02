@uiMultiChoiceOtherFrames @ui @mac-gui @desktop
Feature: The multi-choice sheet decides the group that lies where the clicked one does in the other frames, inside its range and nowhere else

  The rest of E4 of the parity plan: `uiMultiChoiceSheet` has the switch, the sheet and its sentence, Cancel and apply for the frame in view. What apply
  does to the OTHER frames is seen here. The frames of the processed sequence (a static sky) share no group positions, so nothing in the other frames
  would move; the step "the processed copy has the outliers of frame 0 copied into frame 1" makes frame 1's groups frame 0's, pixel for pixel, so
  every group of frame 0 has a twin in frame 1, and the multi-choice sheet's apply reaches it. Frames are counted from 0.

  Scenario: Keep for all frames reaches the twin of the clicked group in the next frame
    Given a processed copy of the sequence {sequence}
      And the processed copy has the outliers of frame 0 copied into frame 1
    When  I open the processed copy
      And I make the window large
      And I click "sequenceprogress.close"
      And I click "mode.edit"
    Then  "frame.number" says "frame 0"
    When  I choose the menu command "removeAll"
    Then  "status.keep" says "0 will keep"
    When  I press "right"
    Then  "frame.number" says "frame 1"
    When  I choose the menu command "removeAll"
    Then  "status.keep" says "0 will keep"
    When  I press "left"
    Then  "frame.number" says "frame 0"
    When  I click "right.multichoice"
      And I click "outlier.first"
    Then  "multichoice.summary" says "Clear overlapping outliers in all 19 frames"
    When  I click "multichoice.apply"
    Then  "multichoice.summary" is not shown
    When  I press "right"
    Then  "frame.number" says "frame 1"
      And "status.keep" stops saying "0 will keep"
