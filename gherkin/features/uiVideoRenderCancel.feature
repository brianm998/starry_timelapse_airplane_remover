@uiVideoRenderCancel @ui @mac-gui @desktop
Feature: Cancelling a render removes its partial video

  P12 of the parity plan. Cancel on a render in progress stops it and takes the half-written video away. What is left on screen afterwards differs
  (the gui puts the dialog away, the desktop returns to the choices), so this asserts only that the progress, the success and the error are gone.

  Scenario: A cancelled render leaves no video
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I choose the menu command "renderVideo"
      And I click "render.start"
      And I click "render.cancel"
    Then  "render.cancel" is not shown
      And "render.done" is not shown
      And "render.error" is not shown
    When  I wait 5 seconds
    Then  no video is left in the output folder
