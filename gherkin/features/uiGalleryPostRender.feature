@uiGalleryPostRender @ui @mac-gui @desktop
Feature: The post-processing render prompt is saved for the gallery

  Parity gallery (plans: ticket #178): saves a screenshot of each screen at the same window size on both clients, for the side-by-side page (gherkin/ui/README.md, "Parity gallery"). It asserts only that each screen comes up; it never compares pictures. Starts from the processed sequence the cli made once; Process All Frames, answered No to the first prompt, ends in it.

  Scenario: The post-processing render prompt is saved for the gallery
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I choose the menu command "processAllFrames"
    Then  "prompt.pre.no" is shown
    When  I click "prompt.pre.no"
    Then  "prompt.post.cancel" is shown
    When  I save a screenshot named "postrender-prompt"
