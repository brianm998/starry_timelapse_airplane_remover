@uiSecondaryWindowsNeedASequence @ui @mac-gui @desktop
Feature: The windows about a sequence are off until one is open

  M11 of the parity plan. The outlier and alignment windows are about the open sequence and cannot be opened without one; the blob and
  debug windows are not, and can be.

  Scenario: The Window menu on the start screen
    Given the app is started with no sequence
    Then  the menu command "outlierWindow" is disabled
      And the menu command "alignmentWindow" is disabled
      And the menu command "blobWindow" is enabled
      And the menu command "debugWindow" is enabled
