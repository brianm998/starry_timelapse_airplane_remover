@uiVideoRenderCancel @ui @mac-gui @desktop
Feature: Cancelling a render removes its partial video

  P12 of the parity plan. Cancel on a render in progress stops it and takes the half-written video away. Both clients put the dialog away afterwards (#322),
  so the progress, the success and the error are all gone. The copy's video settings are VP9 in Matroska, which takes a render longer than the
  few seconds a slow runner needs to get from Render to Cancel (a ten-frame ProRes render was already done by then on Windows).

  Scenario: A cancelled render leaves no video
    Given a processed copy of the sequence {sequence}
      And the processed copy renders with a slow encoder
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
