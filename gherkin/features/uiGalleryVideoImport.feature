@uiGalleryVideoImport @ui @mac-gui @desktop
Feature: The video import dialog is saved for the gallery

  Parity gallery (plans: ticket #178): saves a screenshot of each screen at the same window size on both clients, for the side-by-side page (gherkin/ui/README.md, "Parity gallery"). It asserts only that each screen comes up; it never compares pictures. The video is made from the copied sequence's frames.

  Scenario: The video import dialog is saved for the gallery
    Given a fresh copy of the sequence {sequence}
    When  I open a video of the copied sequence at its import dialog
    Then  "videoimport.import" is shown
    When  I save a screenshot named "video-import"
