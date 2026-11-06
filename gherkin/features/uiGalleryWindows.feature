@uiGalleryWindows @ui @mac-gui @desktop
Feature: The four secondary windows are saved for the gallery

  Parity gallery (plans: ticket #178): saves a screenshot of each screen at the same window size on both clients, for the side-by-side page (gherkin/ui/README.md, "Parity gallery"). It asserts only that each screen comes up; it never compares pictures. Each window is photographed on its own, at the size it opens at.

  Scenario: The four secondary windows are saved for the gallery
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
      And I choose the menu command "outlierWindow"
    Then  the "outlier" window is open
    When  I save a screenshot of the "outlier" window named "window-outlier"
      And I choose the menu command "alignmentWindow"
    Then  the "alignment" window is open
    When  I save a screenshot of the "alignment" window named "window-alignment"
      And I choose the menu command "blobWindow"
    Then  the "blob" window is open
    When  I save a screenshot of the "blob" window named "window-blob"
      And I choose the menu command "debugWindow"
    Then  the "debug" window is open
    When  I save a screenshot of the "debug" window named "window-debug"
