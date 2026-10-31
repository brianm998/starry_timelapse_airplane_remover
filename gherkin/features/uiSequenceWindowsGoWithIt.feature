@uiSequenceWindowsGoWithIt @ui @mac-gui @desktop
Feature: The windows about a sequence close with it

  M11 of the parity plan. With a sequence open the outlier window can be opened; closing the sequence closes it, and the debug window,
  which is not about a sequence, stays.

  Scenario: Open two windows, then close the sequence
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.horizon.no"
      And I click "startup.moving.static"
    Then  the menu command "outlierWindow" is enabled
    When  I choose the menu command "outlierWindow"
      And I choose the menu command "debugWindow"
    Then  the "outlier" window is open
      And the "debug" window is open
    When  I choose the menu command "closeSequence"
    Then  the "outlier" window is not open
      And the "debug" window is open
      And the menu command "outlierWindow" is disabled
