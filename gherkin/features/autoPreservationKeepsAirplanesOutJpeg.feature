@autoPreservationKeepsAirplanesOutJpeg @cli
Feature: automatic preservation keeps airplanes out (JPEG)

  Scenario: automatic:true still removes most labelled airplanes from a JPEG sequence
    Given I open the sequence {sequence}
      And the clean method is automatic:true
     When I process every frame
     Then the labelled airplanes are removed
