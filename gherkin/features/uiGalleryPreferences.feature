@uiGalleryPreferences @ui @mac-gui @desktop
Feature: The preferences are saved for the gallery

  Parity gallery (plans: ticket #178): saves a screenshot of each screen at the same window size on both clients, for the side-by-side page (gherkin/ui/README.md, "Parity gallery"). It asserts only that each screen comes up; it never compares pictures.

  Scenario: The preferences are saved for the gallery
    Given the app is started with no sequence
    When  I open the preferences
    Then  "preferences.close" is shown
    When  I save a screenshot named "preferences"
