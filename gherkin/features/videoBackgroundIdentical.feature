@videoBackgroundIdentical @cli
Feature: processing a video while its frames are extracted gives exactly the output of extracting it first

  Scenario: The output does not depend on when the frames were extracted
    Given the frames have a horizon
      And the camera is static
      And the clean method is automatic
      And I import the video {video} as {frame_format} frames, extracting it in the background
    When  I process every frame
    Then  every input frame has a processed output frame
      And the output frames are identical to those of the same video extracted before processing
      And Star reported no problems
