@uiModePickers @ui @mac-gui @desktop
Feature: The mode and view pickers are the same on both clients

  Q8 of the parity plan. Below the frame are two pickers, "[edit | scrub | grid] with [original | final] frames": edit and the original frames
  are chosen to begin with, and choosing another mode selects it.

  Scenario: Switch to the grid
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
    Then  "mode.edit" is selected
      And "mode.scrub" is not selected
      And "mode.grid" is not selected
      And "view.original" is selected
      And "view.final" is shown
      And "view.final" is not selected
    When  I click "mode.grid"
    Then  "mode.grid" is selected
      And "mode.edit" is not selected
