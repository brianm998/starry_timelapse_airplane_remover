@uiGalleryMultiChoice @ui @mac-gui @desktop
Feature: The multi-choice sheet is saved for the gallery

  Parity gallery (plans: ticket #178): saves a screenshot of each screen at the same window size on both clients, for the side-by-side page (gherkin/ui/README.md, "Parity gallery"). It asserts only that each screen comes up; it never compares pictures. Starts from the processed sequence the cli made once.

  Scenario: The multi-choice sheet is saved for the gallery
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I choose the menu command "removeAll"
    Then  "status.keep" says "0 will keep"
    When  I click "right.multichoice"
      And I click "outlier.first"
    Then  "multichoice.summary" says "Clear overlapping outliers in all 19 frames"
    When  I save a screenshot named "multichoice-sheet"
