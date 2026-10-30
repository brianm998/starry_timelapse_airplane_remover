@autoHorizonVideoBackground @cli @mac-gui @desktop
Feature: automatic clean of a static video with a horizon, processed while its frames are still being extracted

  Scenario: Process a static video with a horizon in automatic mode, extracting the video in the background
    Given the frames have a horizon
      And the camera is static
      And the clean method is automatic
      And I import the video {video} as {frame_format} frames, extracting it in the background
    When  I process every frame
    Then  the run used the requested settings
      And every input frame has a processed output frame
      And the output frames keep the input's format, size and bit depth
      And the output frames were processed in automatic mode
      And Star reported no problems
