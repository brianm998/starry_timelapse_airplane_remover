@uiMultiSelectSheet @ui @mac-gui @desktop
Feature: A drag with the Multi tool opens the area sheet, on Keep and for all frames

  E5 of the parity plan. The Multi tool drags a box over the frame and then asks what to do with the outliers in it, in which frames. The sheet
  starts on Keep (the desktop's used to start on Remove) and on all frames, and the sentence under the choices says what that will do: Keep outliers
  in this area in all 19 frames. Cancel puts the sheet away. Starts from the processed sequence the cli made once, so the frame has groups to drag
  around.

  Scenario: Drag a box with the Multi tool
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I press "7"
      And I drag around "outlier.first"
    Then  "multiselect.summary" says "Keep outliers in this area in all 19 frames"
    When  I click "multiselect.cancel"
    Then  "multiselect.summary" is not shown
