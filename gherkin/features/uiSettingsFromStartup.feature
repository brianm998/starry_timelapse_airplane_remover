@uiSettingsFromStartup @ui @mac-gui @desktop
Feature: The Advanced gear on a startup question opens the processing settings

  P5 and P8 of the parity plan. Each startup question has a gear that jumps to the full processing settings, which both clients
  show with the same buttons: Dismiss (the edits apply as they are made, so there is no Cancel or Save) and Process Now, over
  the same tabs. Dismiss closes the sheet.

  Scenario: Open the settings from the first question and dismiss them
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.advanced"
    Then  "settings.dismiss" is shown
      And "settings.process" is shown
      And "settings.tab.cleaning" is shown
    When  I click "settings.dismiss"
    Then  "settings.process" is not shown
