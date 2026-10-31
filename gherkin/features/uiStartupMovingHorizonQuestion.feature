@uiStartupMovingHorizonQuestion @ui @mac-gui @desktop
Feature: A moving camera with a horizon is asked about selecting its horizons

  After the two answers a sequence with a horizon taken by a camera that moved is asked whether to select the horizons, which is not the
  question a fixed camera is asked.

  Scenario: Horizon, moving camera
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.horizon.yes"
      And I click "startup.moving.moving"
    Then  "startup.selectmovinghorizons.no" is shown
      And "startup.selecthorizon.no" is not shown
      And "startup.removal.start" is not shown
    When  I click "startup.selectmovinghorizons.no"
    Then  "startup.removal.start" is shown
