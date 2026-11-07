@uiVideoRender @ui @mac-gui @desktop
Feature: The Render Video dialog starts from the config, holds a custom frame rate to its rule and writes the video

  P12, P14 and L12 of the parity plan. From the processed sequence the dialog opens with the frame rate the config holds (30, not the first entry of
  the list); choosing Custom starts the field at that rate; a rate outside 0.01 to 1000 shows the message and disables Render, a rate inside takes
  both away; and a valid render writes a video with one frame per frame of the sequence, at the rate typed.

  Scenario: The dialog starts from the config, a custom rate is checked and the render writes the video
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I choose the menu command "renderVideo"
    Then  "render.frame_rate" says "30"
      And "render.custom_frame_rate" is not shown
      And "render.start" is enabled
    When  I click "render.frame_rate"
      And I click the label "ui.custom_2"
    Then  "render.custom_frame_rate" holds the number 30
    When  I type "0" into "render.custom_frame_rate"
    Then  "render.custom_frame_rate.message" says "Enter a number from 0.01 to 1000"
      And "render.start" is disabled
    When  I type "20" into "render.custom_frame_rate"
    Then  "render.custom_frame_rate.message" is not shown
      And "render.start" is enabled
    When  I click "render.start"
    Then  "render.done" is shown
      And the rendered video has one frame per frame of the sequence at 20 frames per second
