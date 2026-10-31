@uiStartupHorizonQuestion @ui @mac-gui @desktop
Feature: A static camera with a horizon is asked about selecting it

  The startup questions are the same on both clients and in the same order. After the two answers a sequence with a horizon taken by a
  camera that did not move is asked whether to select the horizon, before it is asked what to remove.

  Scenario: Horizon, static camera
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.horizon.yes"
      And I click "startup.moving.static"
    Then  "startup.selecthorizon.no" is shown
      And "startup.selecthorizon.yes" is shown
      And "startup.removal.start" is not shown
    When  I click "startup.selecthorizon.no"
    Then  "startup.removal.start" is shown
