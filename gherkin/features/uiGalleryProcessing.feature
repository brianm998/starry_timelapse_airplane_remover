@uiGalleryProcessing @ui @mac-gui @desktop
Feature: The render prompts and the processing modal are saved for the gallery

  Parity gallery (plans: ticket #178): saves a screenshot of each screen at the same window size on both clients, for the side-by-side page (gherkin/ui/README.md, "Parity gallery"). It asserts only that each screen comes up; it never compares pictures.

  Scenario: The render prompts and the processing modal are saved for the gallery
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.advanced"
      And I click "settings.process"
    Then  "prompt.pre.no" is shown
    When  I save a screenshot named "prerender-prompt"
      And I click "prompt.pre.yes"
    Then  "prompt.options.confirm" is shown
    When  I save a screenshot named "prerender-options"
      And I click "prompt.options.confirm"
    Then  "processing.modal" is shown
    When  I save a screenshot named "processing-modal"
