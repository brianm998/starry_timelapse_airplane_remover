@uiOutlierClickKeeps @ui @mac-gui @desktop
Feature: A click on a group to remove makes it one to keep, with the Remove tool chosen

  E1 of the parity plan, the other way: the click flips a group that has a decision whichever tool is chosen, so with the Remove tool a group that is to be
  removed is kept by a click. With every group of the frame removed (Remove All) there is nothing to keep; one click on a group makes it one.

  Scenario: Remove every group, then click one
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I choose the menu command "removeAll"
    Then  "status.keep" says "0 will keep"
    When  I press "1"
      And I click "outlier.first"
    Then  "status.keep" says "1 will keep"
