@removeAirplanes @cli @mac-gui @desktop
Feature: remove airplanes

  Scenario: The automatic clean removes the labelled airplanes and keeps the stars
    Given the frames have a horizon
      And the camera is static
      And the clean method is automatic
      And I open the sequence {sequence}
    When  I process every frame
    Then  the run used the requested settings
      And the labelled airplanes are removed
      And the stars are preserved
