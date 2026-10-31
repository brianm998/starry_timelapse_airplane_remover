@uiMenuCommandsWhilePainting @ui @mac-gui @desktop
Feature: While the horizon painter is open the single-key commands are off, and the painter's own item closes it

  M12 and D9 of the parity plan. The painter is drawn over the edit view, and the keys of the edit view (modes, remove, keep, clear, render, the
  decision tree, play) do nothing behind it, so their menu items are off. The item that opened the painter now closes it, and the commands that
  do not act on the frame stay on. Closing the painter turns them back on.

  Scenario: Open the painter and close it again
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
      And I choose the menu command "paintHorizon"
    Then  the menu command "closeHorizonPainter" is enabled
      And the menu command "editMode" is disabled
      And the menu command "scrubMode" is disabled
      And the menu command "gridMode" is disabled
      And the menu command "removeAll" is disabled
      And the menu command "keepAll" is disabled
      And the menu command "clearUndecided" is disabled
      And the menu command "playPause" is disabled
      And the menu command "decisionTreeAllFrames" is disabled
      And the menu command "renderThisFrame" is disabled
      And the menu command "processAllFrames" is enabled
      And the menu command "processingSettings" is enabled
      And the menu command "toggleSidePanels" is enabled
    When  I choose the menu command "closeHorizonPainter"
    Then  the menu command "editMode" is enabled
      And the menu command "removeAll" is enabled
