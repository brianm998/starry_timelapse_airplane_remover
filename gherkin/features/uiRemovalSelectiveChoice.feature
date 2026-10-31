@uiRemovalSelectiveChoice @ui @mac-gui @desktop
Feature: Choosing selective removal replaces the automatic choice

  The two ways to remove are alternatives: choosing selective selects it and not automatic, and takes away the switch that only
  automatic removal has (auto selective). Choosing automatic again brings it back.

  Scenario: Selective, then automatic again
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.horizon.no"
      And I click "startup.moving.static"
      And I click "startup.removal.selective"
    Then  "startup.removal.selective" is selected
      And "startup.removal.automatic" is not selected
      And "startup.removal.autoselective" is not shown
    When  I click "startup.removal.automatic"
    Then  "startup.removal.automatic" is selected
      And "startup.removal.selective" is not selected
      And "startup.removal.autoselective" is shown
