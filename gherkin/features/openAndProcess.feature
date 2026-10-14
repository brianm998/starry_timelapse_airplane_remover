@openAndProcess @cli @mac-gui @desktop
Feature: open and process

  Scenario: Process the bundled test sequence
    Given I open the sequence {sequence}
     When I process every frame
     Then {expected_outputs} output frames are written
