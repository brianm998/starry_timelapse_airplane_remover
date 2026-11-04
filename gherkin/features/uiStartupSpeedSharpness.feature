@uiStartupSpeedSharpness @ui @mac-gui @desktop
Feature: Speed vs. Sharpness is a summary row with an Update modal

  The cleanup dialog shows one line for Speed vs. Sharpness and an Update button. Update opens a modal with Cancel on the left and Update on the right, and both return to the cleanup dialog.

  Scenario: Open the modal from the cleanup dialog and leave it with Cancel, then with Update
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.horizon.no"
      And I click "startup.moving.static"
    Then  "startup.removal.start" is shown
      And "startup.removal.speed.update" is shown
      And "startup.speed.update" is not shown
    When  I click "startup.removal.speed.update"
    Then  "startup.speed.cancel" is shown
      And "startup.speed.update" is shown
    When  I click "startup.speed.cancel"
    Then  "startup.removal.start" is shown
      And "startup.speed.update" is not shown
    When  I click "startup.removal.speed.update"
    Then  "startup.speed.update" is shown
    When  I click "startup.speed.update"
    Then  "startup.removal.start" is shown
      And "startup.speed.update" is not shown
