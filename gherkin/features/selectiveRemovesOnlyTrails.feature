@selectiveRemovesOnlyTrails @cli
Feature: selective removes only trails

  Scenario: selective removes the pinned airplanes and changes nothing else in a lossless sequence
    Given the frames have a horizon
      And the camera is static
      And the clean method is selective
      And I open the sequence {sequence}
    When  I process every frame
    Then  the run used the requested settings
      And the labelled airplanes are removed
      And nothing outside the labelled trails changed
      And the stars are preserved
