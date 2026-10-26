@autoPreservationKeepsAirplanesOutBit16 @cli
Feature: automatic preservation keeps airplanes out (16-bit)

  Scenario: auto selective still removes most labelled airplanes from a 16-bit sequence
    Given the frames have a horizon
      And the camera is static
      And the clean method is auto selective
      And I open the sequence {sequence}
    When  I process every frame
    Then  the run used the requested settings
      And the labelled airplanes are removed
