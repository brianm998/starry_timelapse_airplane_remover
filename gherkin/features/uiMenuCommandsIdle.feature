@uiMenuCommandsIdle @ui @mac-gui @desktop
Feature: With a sequence open and nothing running, the menu commands are on, except Cancel Processing

  M12 and D9 of the parity plan. The menu is one tree on both clients, and which items are on in which state is the gui's: with a sequence open and
  nothing running every command can be chosen, and Cancel Processing cannot, because there is no run to cancel.

  Scenario: The commands of an open sequence
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
    Then  the menu command "processAllFrames" is enabled
      And the menu command "processFramesFromHere" is enabled
      And the menu command "processCurrentFrame" is enabled
      And the menu command "reprocessCurrentFrame" is enabled
      And the menu command "findOutliersCurrentFrame" is enabled
      And the menu command "decisionTreeAllFrames" is enabled
      And the menu command "renderThisFrame" is enabled
      And the menu command "renderAllFrames" is enabled
      And the menu command "processingSettings" is enabled
      And the menu command "renderVideo" is enabled
      And the menu command "removeAll" is enabled
      And the menu command "keepAll" is enabled
      And the menu command "clearUndecided" is enabled
      And the menu command "editMode" is enabled
      And the menu command "scrubMode" is enabled
      And the menu command "gridMode" is enabled
      And the menu command "playPause" is enabled
      And the menu command "toggleSidePanels" is enabled
      And the menu command "toggleFilmstrip" is enabled
      And the menu command "paintHorizon" is enabled
      And the menu command "closeSequence" is enabled
      And the menu command "cancelProcessing" is disabled
