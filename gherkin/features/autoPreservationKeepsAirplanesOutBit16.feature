@autoPreservationKeepsAirplanesOutBit16 @cli
Feature: automatic preservation keeps airplanes out (16-bit)

  Scenario: automatic:true still removes most labelled airplanes from a 16-bit sequence
    Given I open the 16-bit sequence {sequence16}
      And the clean method is automatic:true
     When I process every frame
     Then the labelled airplanes are removed
