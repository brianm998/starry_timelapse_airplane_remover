@uiMultiSheetChoices @ui @mac-gui @desktop
Feature: The area sheet's range choices change its sentence, and the sheet is left as it was set

  E4 and E5 of the parity plan. The Multi tool's area sheet asks which frames to change. All frames is the first choice; from this frame to the end
  and from the start to this frame each say, in the sentence under the choices, how many frames that is and which one is this; "some frames" (this
  frame and some after) has no sentence and a number field that starts on 50. The sheet keeps what it was left with: after Cancel, a second box
  drawn in the same sequence opens it on the range and the action it was left on. (The generator allows one scenario per feature, so the second
  opening is the second half of this one.) Starts from the processed sequence the cli made once.

  Scenario: Choose ranges in the area sheet, cancel it, and open it again
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I press "7"
      And I drag around "outlier.first"
    Then  "multiselect.summary" says "Keep outliers in this area in all 19 frames"
    When  I click "multiselect.range.allAfter"
    Then  "multiselect.summary" says "Keep outliers in this area in 19 frames from frame 0 to the end"
    When  I click "multiselect.range.someAfter"
    Then  "multiselect.count" holds the number 50
      And "multiselect.summary" is not shown
    When  I click "multiselect.range.allBefore"
    Then  "multiselect.summary" says "Keep outliers in this area in 1 frames from the start ending at frame 0"
    When  I click "multiselect.action.removeOverlaps"
    Then  "multiselect.summary" says "Remove overlaying outliers in this area in 1 frames from the start ending at frame 0"
    When  I click "multiselect.cancel"
      And I drag around "outlier.first"
    Then  "multiselect.summary" says "Remove overlaying outliers in this area in 1 frames from the start ending at frame 0"
