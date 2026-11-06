@uiMultiChoiceSheet @ui @mac-gui @desktop
Feature: With Multi Choice on, a click on a decided group opens the sheet; Cancel changes nothing and applying it does

  E4 of the parity plan. The "Multi Choice" switch makes a click on a group that has a decision ask what to do with the groups that overlap it in
  the other frames, instead of flipping that one. The sheet starts on the opposite of what the group has (a removed group offers Keep), for all the
  frames, and says what applying it will do: Clear overlapping outliers in all 19 frames. Cancel puts it away and leaves every decision as it was;
  applying puts it away and keeps the group, and whatever overlaps it, in every frame of the range. (No group of this sequence's other frames lies
  where the first group does, so what happens to those frames is not seen here: the daemon's and StarCore's tests hold it.) Starts from the
  processed sequence the cli made once, so the frame has groups.

  Scenario: Remove every group, then look at the sheet, cancel it, and apply it
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I choose the menu command "removeAll"
    Then  "status.keep" says "0 will keep"
      And "status.remove" stops saying "0 will remove"
    When  I click "right.multichoice"
    Then  "right.multichoice" is on
    When  I click "outlier.first"
    Then  "multichoice.summary" says "Clear overlapping outliers in all 19 frames"
    When  I click "multichoice.cancel"
    Then  "multichoice.summary" is not shown
      And "status.keep" is still saying "0 will keep"
    When  I click "outlier.first"
      And I click "multichoice.apply"
    Then  "multichoice.summary" is not shown
      And "status.keep" stops saying "0 will keep"
