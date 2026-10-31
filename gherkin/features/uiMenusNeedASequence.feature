@uiMenusNeedASequence @ui @mac-gui @desktop
Feature: Actions and Tools are in the menu bar only while a sequence is open

  M12 of the parity plan, settled by the owner. The menus of what to do with a sequence's frames are not there on the start screen, in either client: the
  menu bar is File and Window (and the desktop's Language) until one is open. The Window menu is there at all times.

  Scenario: The menu bar on the start screen
    Given the app is started with no sequence
    Then  the menu "file" is there
      And the menu "window" is there
      And the menu "actions" is not there
      And the menu "tools" is not there
