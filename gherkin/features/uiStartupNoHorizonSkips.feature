@uiStartupNoHorizonSkips @ui @mac-gui @desktop
Feature: A sequence with no horizon is not asked about selecting one

  Without a horizon the question about selecting it has nothing to ask: the second answer leads straight to what to remove.

  Scenario: No horizon
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.horizon.no"
      And I click "startup.moving.static"
    Then  "startup.removal.start" is shown
      And "startup.selecthorizon.no" is not shown
      And "startup.selectmovinghorizons.no" is not shown
