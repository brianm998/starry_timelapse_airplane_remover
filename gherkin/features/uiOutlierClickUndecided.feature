@uiOutlierClickUndecided @ui @mac-gui @desktop
Feature: A click with the Keep tool on a group nobody has decided keeps it

  E1 of the parity plan. A click on a group that has no decision gives it the tool's: the Keep tool keeps it and every other tool removes it. (The
  click used to ignore the tool, so Keep marked an undecided group for removal.) The processed frame starts with groups nobody has decided (selective
  leaves them to the user): one click with the Keep tool makes one of them a group to keep, and none of them one to remove.

  Scenario: Click an undecided group with the Keep tool
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
    Then  "status.keep" says "0 will keep"
      And "status.remove" says "0 will remove"
    When  I press "2"
      And I click "outlier.first"
    Then  "status.keep" says "1 will keep"
      And "status.remove" says "0 will remove"
