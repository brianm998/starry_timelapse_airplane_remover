@syntheticSatellites @cli
Feature: synthetic satellites

  Scenario: The automatic clean removes every injected satellite, whatever its brightness
    Given the frames have no horizon
      And the camera is static
      And the clean method is automatic
      And I open the sequence {sequence}
    When  I process the injected sequence and its base
    Then  the labelled satellites are removed
