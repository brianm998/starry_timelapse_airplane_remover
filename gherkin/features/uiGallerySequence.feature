@uiGallerySequence @ui @mac-gui @desktop
Feature: The sequence screen in each mode and the horizon painter are saved for the gallery

  Parity gallery (plans: ticket #178): saves a screenshot of each screen at the same window size on both clients, for the side-by-side page (gherkin/ui/README.md, "Parity gallery"). It asserts only that each screen comes up; it never compares pictures.

  Scenario: The sequence screen in each mode and the horizon painter are saved for the gallery
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
    Then  "mode.edit" is selected
    When  I save a screenshot named "sequence-edit"
      And I click "mode.scrub"
    Then  "mode.scrub" is selected
    When  I save a screenshot named "sequence-scrub"
      And I click "mode.grid"
    Then  "grid.cell.0" is shown
    When  I save a screenshot named "sequence-grid"
      And I click "mode.edit"
      And I choose the menu command "paintHorizon"
    Then  the menu command "closeHorizonPainter" is enabled
    When  I save a screenshot named "horizon-painter"
