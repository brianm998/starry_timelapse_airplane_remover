@uiTranslatedScreen @ui @mac-gui @desktop
Feature: A client run in another language shows the catalogue's words for it, on every screen it opens

  I1 of the parity plan. Each client takes the language from STAR_LANG (or the system), and every word it draws is the catalogue's for that language:
  the gui had texts that were English in StarCore whatever the language was. Run in German, the startup question, the processing settings sheet and the
  sequence screen's pickers read what de.json says for them, which is not what en.json says.

  Scenario: The startup question, the settings sheet and the pickers in German
    Given the language is "de"
      And a fresh copy of the sequence {sequence}
    When  I open the copied sequence
    Then  "startup.horizon.yes" reads "ui.yes"
      And "startup.horizon.no" reads "ui.no"
    When  I click "startup.advanced"
    Then  "settings.dismiss" reads "ui.dismiss"
      And "settings.process" reads "ui.process_now"
      And "settings.tab.cleaning" reads "settings_tab.cleaning"
    When  I click "settings.dismiss"
    Then  "mode.edit" reads "interaction_mode.edit"
      And "mode.scrub" reads "interaction_mode.scrub"
      And "mode.grid" reads "interaction_mode.grid"
      And "view.final" reads "ui.view_processed"
