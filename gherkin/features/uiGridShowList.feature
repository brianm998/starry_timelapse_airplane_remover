@uiGridShowList @ui @mac-gui @desktop
Feature: The grid's Show list, its finished-frame badges and its right panel's counts

  Parity findings Q2, Q12 and Q13 (plans/GUI_CLIENT_PARITY_PLAN.md, §6.3). In grid mode of a processed sequence the left panel's Show list offers the original,
  the final frame and the other images the frames have, in the gui's order; a finished frame's cell carries no state badge; and the right panel counts a
  frame's outliers once they are loaded. Starts from the processed sequence the cli made once.

  Scenario: The grid lists its modes, a finished cell has no badge and the panel counts the outliers
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
    Then  "sequenceprogress.close" is shown
    When  I click "sequenceprogress.close"
      And I click "mode.edit"
    Then  "status.state" says "frame is complete"
    When  I click "mode.grid"
    Then  "grid.cell.0" is shown
      And "grid.show.original" is shown
      And "grid.show.final" is shown
      And "grid.show.original" is above "grid.show.final"
      And "grid.show.dirtyEarthProcessed" is not shown
      And "grid.badge.0" is not shown
    When  I click "grid.cell.0"
    Then  "grid.panel.outliers" is shown
      And "grid.panel.positive" is shown
