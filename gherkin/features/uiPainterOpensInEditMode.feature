@uiPainterOpensInEditMode @ui @mac-gui @desktop
Feature: The horizon painter opens in edit mode, from whichever mode the sequence is in

  M7 of the parity plan. The painter is drawn over the edit view, so choosing Paint Reference Horizon from scrub or grid mode switches to edit
  first; it used to set the painter's flag and show nothing, and the single-key commands went dead behind it. The same item then closes it.

  Scenario: Open the painter from scrub, close it, and open it from the grid
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
      And I click "mode.scrub"
    Then  "mode.scrub" is selected
    When  I choose the menu command "paintHorizon"
    Then  "mode.edit" is selected
      And the menu command "closeHorizonPainter" is enabled
    When  I choose the menu command "closeHorizonPainter"
      And I click "mode.grid"
    Then  "mode.grid" is selected
    When  I choose the menu command "paintHorizon"
    Then  "mode.edit" is selected
      And the menu command "closeHorizonPainter" is enabled
