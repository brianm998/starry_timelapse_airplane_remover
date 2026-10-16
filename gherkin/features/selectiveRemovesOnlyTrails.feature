@selectiveRemovesOnlyTrails @cli
Feature: selective removes only trails

  Scenario: selective removes the pinned airplanes and changes nothing else in a lossless sequence
    Given I open the 16-bit sequence {sequence16}
      And the clean method is selective
     When I process every frame
     Then the labelled airplanes are removed
      And nothing outside the labelled trails changed
      And the stars are preserved
