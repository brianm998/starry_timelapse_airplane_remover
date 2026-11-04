@uiGalleryLocation @ui @mac-gui @desktop
Feature: The sequence location question is saved for the gallery

  Parity gallery (plans: ticket #178): saves a screenshot of each screen at the same window size on both clients, for the side-by-side page (gherkin/ui/README.md, "Parity gallery"). It asserts only that each screen comes up; it never compares pictures.

  Scenario: The sequence location question is saved for the gallery
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence at its location question
    Then  "sequencelocation.open" is shown
    When  I save a screenshot named "sequence-location"
