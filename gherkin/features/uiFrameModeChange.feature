@uiFrameModeChange @ui @mac-gui @desktop
Feature: Changing a frame's processing mode leaves the frame complete

  L10 of the parity plan. Change Mode on the right panel puts the frame on another processing mode (the dialog applies it on OK). The frame has its
  new mode's final image at once and stays complete: it used to be recorded and then, ten seconds on, rendered again and left user modified. The
  panel says the mode is now the frame's own (custom), and a look a moment after the change, and another after the ten seconds are gone, says the frame is complete: a check that does not wait for it to become so. Starts from the
  processed sequence the cli made once (selective, so the frame begins on Selective).

  Scenario: Change a selective frame to automatic
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
    Then  "status.state" says "frame is complete"
      And "right.mode" says "Selective (default)"
    When  I click "right.changemode"
      And I click the label "ui.automatic"
      And I click "changemode.ok"
    Then  "changemode.ok" is not shown
      And "right.mode" says "Automatic (custom)"
    When  I wait 3 seconds
    Then  "status.state" is still saying "frame is complete"
    When  I wait 12 seconds
    Then  "status.state" is still saying "frame is complete"
      And "right.mode" is still saying "Automatic (custom)"
