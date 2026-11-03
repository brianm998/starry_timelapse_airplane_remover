@uiGalleryProcessed @ui @mac-gui @desktop
Feature: The screens of a processed sequence are saved for the gallery

  Parity gallery (plans: ticket #178): saves a screenshot of each screen at the same window size on both clients, for the side-by-side page (gherkin/ui/README.md, "Parity gallery"). It asserts only that each screen comes up; it never compares pictures.
  The sequence-progress dialog a reopened sequence shows, the change-mode dialog and the render video dialog. Starts from the processed sequence the cli made once.

  Scenario: The screens of a processed sequence are saved for the gallery
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
    Then  "sequenceprogress.close" is shown
    When  I save a screenshot named "sequence-progress"
      And I click "sequenceprogress.close"
      And I click "mode.edit"
    Then  "status.state" says "frame is complete"
    When  I save a screenshot named "processed-edit"
      And I click "right.changemode"
    Then  "changemode.ok" is shown
    When  I save a screenshot named "changemode"
      And I click "changemode.ok"
    Then  "changemode.ok" is not shown
    When  I choose the menu command "renderVideo"
    Then  "render.cancel" is shown
    When  I save a screenshot named "render-video"
