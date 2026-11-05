@uiPainterWaitsForExtraction @ui @mac-gui @desktop
Feature: The horizon painter waits for a video frame that is not extracted yet

  H3 of the parity plan. A video's frames are extracted in the background. The painter opened on a frame that has not arrived stays in its
  computing state, not starting a session on a blank frame, and goes on to the frame's own state (band selection, when it has no horizon
  yet) once the frame is there. The extraction is held back from the second frame on by a file beside the video (a seam in StarCore's
  VideoFrameSource) until the step that releases it. Loading a horizon that was saved for the frame once it arrives is pinned by the desktop's
  HorizonPainterWaitTest: a feature would need a horizon saved for a frame that has not been extracted, which only a second painter session
  can make.

  Scenario: Open the painter on a frame that is held back, then let it arrive
    Given a fresh copy of the sequence {sequence}
    When  I open a video of the copied sequence with its extraction held
      And I choose the menu command "paintHorizon"
      And I press "right"
    Then  "frame.number" says "frame 1"
      And "painter.computing" is shown
      And "painter.band" is not shown
      And "extraction.waitpanel" is shown
    When  the video's extraction is released
    Then  "painter.band" is shown
      And "painter.computing" is not shown
      And "extraction.waitpanel" is not shown
