@autoHorizonJpegVideoOut @cli @mac-gui @desktop
Feature: automatic clean of a static JPEG sequence with a horizon, rendered to video

  Scenario: Process a static JPEG sequence with a horizon in automatic mode and render the output video
    Given the frames have a horizon
      And the camera is static
      And the clean method is automatic
      And I open the sequence {sequence}
    When  I process every frame
      And I render the output video
    Then  the run used the requested settings
      And every input frame has a processed output frame
      And the output frames keep the input's format, size and bit depth
      And the output frames were processed in automatic mode
      And the output video has one frame per output frame
      And Star reported no problems
