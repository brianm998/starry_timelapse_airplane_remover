@uiProcessingModalPlanning @ui @mac-gui @desktop
Feature: The processing screen stops saying it is planning once the plan is built, and Return on it is Preview

  P1 and P13 of the parity plan. Process All puts up the processing screen, whose headline reads the planning line until the frame graph is built (the
  desktop's `graph_built`, the gui's `graphBuildsCompleted > processingBuildCount`) and what the steps are doing after it. Return on the screen presses
  its default button, Preview, which puts the screen away and leaves the run going.

  What this does not check is that the planning line was ever up: on these ten frames the plan is built in well under a second, and the desktop's
  first look at the headline (measured, a poll every 5 ms from the click's return) already read "Working on: ...", so `is still saying` on the planning
  line cannot hold there. The planning line itself is held by the headline's unit tests on both sides (`ProcessingHeadline`, and the gui's
  `starTests` copy check); no delay was added to planning to catch it. What it does check is that the headline is there and moves on from it.

  Scenario: Process All's headline moves on from planning, and Return is Preview
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.advanced"
      And I click "settings.process"
    Then  "prompt.pre.no" is shown
    When  I click "prompt.pre.no"
    Then  "processing.modal" is shown
      And "processing.headline" is shown
      And "processing.headline" stops saying "Planning the run: working out which steps each frame still needs."
    When  I press "return"
    Then  "processing.modal" is not shown
    When  I click "mode.edit"
      And I wait for processing to finish
