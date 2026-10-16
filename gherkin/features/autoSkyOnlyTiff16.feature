@autoSkyOnlyTiff16 @cli @mac-gui @desktop
Feature: automatic clean of a static 16-bit TIFF sky-only sequence

  Scenario: Process a static 16-bit TIFF sky-only sequence in automatic mode
    Given the frames have no horizon
      And the camera is static
      And the clean method is automatic
      And I open the sequence {sequence}
    When  I process every frame
    Then  the run used the requested settings
      And every input frame has a processed output frame
      And the output frames keep the input's format, size and bit depth
      And the output frames were processed in automatic mode
      And Star reported no problems
