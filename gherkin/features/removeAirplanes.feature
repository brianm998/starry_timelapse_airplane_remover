@removeAirplanes @cli @mac-gui @desktop
Feature: remove airplanes

  Scenario: The default clean method removes the labelled airplanes and keeps the stars
    Given I open the sequence {sequence}
     When I process every frame
     Then the labelled airplanes are removed
      And the stars are preserved
