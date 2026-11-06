@uiGalleryStart @ui @mac-gui @desktop
Feature: The start screen is saved for the gallery

  Parity gallery (plans: ticket #178): saves a screenshot of each screen at the same window size on both clients, for the side-by-side page (gherkin/ui/README.md, "Parity gallery"). It asserts only that each screen comes up; it never compares pictures.
  The start screen with recent sequences listed, so that every button is there.

  Scenario: The start screen is saved for the gallery
    Given the preferences have 3 recent sequences
      And the app is started with no sequence
    Then  "startup.recent.open" is shown
    When  I save a screenshot named "start"
