@uiOutlierWindowRows @ui @mac-gui @desktop
Feature: The outlier window lists the current frame's groups and follows the frame

  E6 of the parity plan. Opened from the Window menu, the outlier window lists every large group of the frame being looked at (the gui's used to
  list only the rows an Information-tool drag had filled, so none), and when the frame changes it lists the new frame's: its title says which frame
  it is for and its heading counts that frame's groups. Starts from the processed sequence the cli made once.

  Scenario: The window lists the frame and follows it
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I choose the menu command "outlierWindow"
    Then  the "outlier" window is open
      And the "outlier" window is titled "Outliers for frame 0"
      And "outlier.rows" holds the number 0
    When  I click "mode.edit"
      And I press "right"
    Then  the "outlier" window is titled "Outliers for frame 1"
      And "outlier.rows" holds the number 0
