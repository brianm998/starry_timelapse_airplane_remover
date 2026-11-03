@uiSettingsProcessNow @ui @mac-gui @desktop
Feature: Process Now in the settings starts processing

  The Process Now button on the settings sheet applies what is pending and goes on to processing, which asks first whether to render a
  video afterwards, as it does from the question about what to remove, and then puts up the processing screen.

  Scenario: Process Now from the settings
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.advanced"
      And I click "settings.process"
    Then  "prompt.pre.no" is shown
      And "settings.process" is not shown
    When  I click "prompt.pre.no"
    Then  "processing.modal" is shown
