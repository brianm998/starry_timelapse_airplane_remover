@uiStartupBackToHorizon @ui @mac-gui @desktop
Feature: Back on the camera question returns to the horizon question

  Both clients let a user correct the first answer without starting over: the Back control on the second question leads to the first.

  Scenario: Answer the horizon question, go back, see it again
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.horizon.no"
    Then  "startup.moving.static" is shown
      And "startup.back" is shown
    When  I click "startup.back"
    Then  "startup.horizon.yes" is shown
      And "startup.moving.static" is not shown
