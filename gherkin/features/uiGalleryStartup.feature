@uiGalleryStartup @ui @mac-gui @desktop
Feature: The startup questions and the settings sheet are saved for the gallery

  Parity gallery (plans: ticket #178): saves a screenshot of each screen at the same window size on both clients, for the side-by-side page (gherkin/ui/README.md, "Parity gallery"). It asserts only that each screen comes up; it never compares pictures.

  Scenario: The startup questions and the settings sheet are saved for the gallery
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
    Then  "startup.horizon.yes" is shown
    When  I save a screenshot named "startup-horizon"
      And I click "startup.advanced"
    Then  "settings.process" is shown
    When  I save a screenshot named "settings-cleaning"
      And I click "settings.tab.gpu"
      And I save a screenshot named "settings-gpu"
      And I click "settings.tab.alignment"
      And I save a screenshot named "settings-alignment"
      And I click "settings.tab.horizon"
      And I save a screenshot named "settings-horizon"
      And I click "settings.tab.memory"
      And I save a screenshot named "settings-memory"
      And I click "settings.dismiss"
    Then  "settings.process" is not shown
    When  I click "startup.horizon.yes"
      And I click "startup.moving.moving"
    Then  "startup.selectmovinghorizons.no" is shown
    When  I save a screenshot named "startup-moving-horizon"
      And I click "startup.selectmovinghorizons.no"
    Then  "startup.removal.start" is shown
    When  I save a screenshot named "startup-removal"
