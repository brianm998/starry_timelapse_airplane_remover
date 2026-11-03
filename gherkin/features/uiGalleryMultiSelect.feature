@uiGalleryMultiSelect @ui @mac-gui @desktop
Feature: The multi-select sheet is saved for the gallery

  Parity gallery (plans: ticket #178): saves a screenshot of each screen at the same window size on both clients, for the side-by-side page (gherkin/ui/README.md, "Parity gallery"). It asserts only that each screen comes up; it never compares pictures. Starts from the processed sequence the cli made once.

  Scenario: The multi-select sheet is saved for the gallery
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I press "7"
      And I drag around "outlier.first"
    Then  "multiselect.summary" says "Keep outliers in this area in all 19 frames"
    When  I save a screenshot named "multiselect-sheet"
