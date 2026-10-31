@uiStartupDefaults @ui @mac-gui @desktop
Feature: The question about what to remove starts where the gui's does

  L1 of the parity plan. A sequence opened for the first time is offered the same choices in the same state on both clients: automatic removal
  chosen, selective not, the automatic mode's auto selective switch off, and the ground alignment switch on.

  Scenario: The removal question's initial state
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.horizon.no"
      And I click "startup.moving.static"
    Then  "startup.removal.automatic" is selected
      And "startup.removal.selective" is not selected
      And "startup.removal.autoselective" is off
      And "startup.removal.groundalignment" is on
