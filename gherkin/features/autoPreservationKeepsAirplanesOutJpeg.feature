@autoPreservationKeepsAirplanesOutJpeg @cli
Feature: automatic preservation keeps airplanes out (JPEG)

  Scenario: auto selective still removes most labelled airplanes from a JPEG sequence
    Given the frames have a horizon
      And the camera is static
      And the clean method is auto selective
      And I open the sequence {sequence}
    When  I process every frame
    Then  the run used the requested settings
      And the labelled airplanes are removed
