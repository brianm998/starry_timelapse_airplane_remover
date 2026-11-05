@uiRenderAllFrames @ui @mac-gui @desktop
Feature: Render All Frames is Process All with the question about rendering the video

  L4 of the parity plan (D7). Actions > Render All Frames asks the render question first, as Process All Frames does, and then starts a processing run. The
  desktop used to finish the frames from disk, with no question and no processing screen. The desktop's menu item cannot be tagged (an AWT menu), so the
  feature reaches it by its menu command on both clients. The question is answered "no", so the video itself (its own feature) is not rendered.

  Scenario: Render All Frames asks the render question and starts a run
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
      And I choose the menu command "renderAllFrames"
    Then  "prompt.pre.no" is shown
    When  I click "prompt.pre.no"
    Then  "processing.modal" is shown
