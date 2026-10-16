@selectiveHorizonTiff16 @cli @mac-gui @desktop
Feature: selective clean of a static 16-bit TIFF sequence with a horizon

  Scenario: Process a static 16-bit TIFF sequence with a horizon in selective mode
    Given the frames have a horizon
      And the camera is static
      And the clean method is selective
      And I open the sequence {sequence}
    When  I process every frame
    Then  the run used the requested settings
      And every input frame has a processed output frame
      And the output frames keep the input's format, size and bit depth
      And the output frames were processed in selective mode
      And Star reported no problems
