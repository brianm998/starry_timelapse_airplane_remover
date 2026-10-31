@uiSettingsExpertToggle @ui @mac-gui @desktop
Feature: The expert settings are shown and hidden with a button

  P8 of the parity plan. The expert settings button says what it will do, and says the opposite once it has: it is a button, as in the gui,
  and not a switch among the settings.

  Scenario: Show the expert settings, then hide them
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.advanced"
    Then  "settings.expert" reads "ui.show_expert_settings"
    When  I click "settings.expert"
    Then  "settings.expert" reads "ui.hide_expert_settings"
    When  I click "settings.expert"
    Then  "settings.expert" reads "ui.show_expert_settings"
