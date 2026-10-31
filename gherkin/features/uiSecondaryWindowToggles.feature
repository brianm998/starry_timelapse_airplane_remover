@uiSecondaryWindowToggles @ui @mac-gui @desktop
Feature: A Window menu item opens its window once and closes it the next time

  M11 of the parity plan. Each secondary window has one instance, and its menu item (and shortcut) toggles it: the first choice opens
  it, the next closes it. It used to open a new copy every time.

  Scenario: Toggle the debug window
    Given the app is started with no sequence
    When  I choose the menu command "debugWindow"
    Then  the "debug" window is open
    When  I choose the menu command "debugWindow"
    Then  the "debug" window is not open
