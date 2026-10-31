@uiStartupReturnStarts @ui @mac-gui @desktop
Feature: Return answers the question about what to remove

  S5 of the parity plan. Both clients put the same question to a user who has opened a sequence and answered the two before it, and on both
  Return does what the default button does: it goes on to processing, which asks first whether to render a video afterwards.

  Scenario: Return on the removal question starts processing
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.horizon.no"
      And I click "startup.moving.static"
    Then  "startup.removal.start" is shown
    When  I press "return"
    Then  "prompt.pre.no" is shown
      And "startup.removal.start" is not shown
