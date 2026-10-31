@uiStartupBackFromRemoval @ui @mac-gui @desktop
Feature: Back on the question about what to remove returns to the camera question

  With no horizon there is no question about selecting it, so the question before the one about what to remove is the camera's.

  Scenario: Answer both questions, go back from the removal question
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.horizon.no"
      And I click "startup.moving.static"
    Then  "startup.removal.start" is shown
      And "startup.back" is shown
    When  I click "startup.back"
    Then  "startup.moving.static" is shown
      And "startup.removal.start" is not shown
