@uiDecisionTreeCommandsIdle @ui @mac-gui @desktop
Feature: The decision-tree commands are on whatever the clean method is

  M12 of the parity plan. Apply Decision Tree and its Auto Only form are always on in the gui's Actions menu while a sequence is open. The desktop
  greys them for a clean method that reviews no outliers (plain Automatic), which the sequence starts with here.

  Scenario: The commands of an open sequence that was never asked how to clean it
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
    Then  the menu command "decisionTreeAll" is enabled
      And the menu command "decisionTreeAutoOnly" is enabled
