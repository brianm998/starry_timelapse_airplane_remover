@uiRecentsRemove @ui @mac-gui @desktop
Feature: The recent list's remove button takes the shown sequence off the list

  D12 of the parity plan. A recent sequence can be removed from the list, and the removal reaches the preferences file, where the other
  client's entries stay. The button goes with the last entry.

  Scenario: Remove both recents
    Given the preferences have 2 recent sequences
      And the app is started with no sequence
    When  I click "startup.recent.remove"
    Then  the preferences file lists 1 recent sequences
    When  I click "startup.recent.remove"
    Then  the preferences file lists 0 recent sequences
      And "startup.recent.remove" is not shown
