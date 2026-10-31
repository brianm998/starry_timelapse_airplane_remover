@uiOutlierClicks @ui @mac-gui @desktop
Feature: A click on a kept outlier group makes it one to remove

  E1 of the parity plan, settled by the owner: a click on a group that has a decision flips it, whichever tool is chosen. With every group of the frame
  kept (Keep All) there is nothing to remove; one click on a group, with the Remove tool, makes it one. Starts from the processed sequence the cli made
  once, so the frame has groups.

  Scenario: Keep every group, then click one
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I choose the menu command "keepAll"
    Then  "status.remove" says "0 will remove"
    When  I press "1"
      And I click "outlier.first"
    Then  "status.remove" says "1 will remove"
