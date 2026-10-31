@uiSettingsTabs @ui @mac-gui @desktop
Feature: The processing settings are in tabs

  The settings sheet is five tabs, Cleaning, GPU Usage, Alignment, Horizon and Memory, in both clients, and there is no expert button hiding half of
  it. Every tab can be opened, and the sheet's buttons stay up whichever one is.

  Scenario: Open the settings and visit every tab
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.advanced"
    Then  "settings.tab.cleaning" reads "settings_tab.cleaning"
      And "settings.tab.gpu" reads "settings_tab.gpu"
      And "settings.tab.alignment" reads "settings_tab.alignment"
      And "settings.tab.horizon" reads "settings_tab.horizon"
      And "settings.tab.memory" reads "settings_tab.memory"
    When  I click "settings.tab.gpu"
    Then  "settings.process" is shown
    When  I click "settings.tab.alignment"
    Then  "settings.process" is shown
    When  I click "settings.tab.horizon"
    Then  "settings.process" is shown
    When  I click "settings.tab.memory"
    Then  "settings.process" is shown
    When  I click "settings.tab.cleaning"
    Then  "settings.process" is shown
