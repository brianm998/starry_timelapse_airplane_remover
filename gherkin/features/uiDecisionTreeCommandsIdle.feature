@uiDecisionTreeCommandsIdle @ui @mac-gui @desktop
Feature: The decision-tree commands are on whatever the clean method is

  M12 of the parity plan, settled by the owner: Apply Decision Tree and its Auto Only form are on whenever a sequence is open, as the gui's Actions menu
  has them, and not greyed for a clean method that reviews no outliers (plain Automatic, which the sequence starts with here). Chosen with nothing to
  classify they do nothing.

  Scenario: The commands of an open sequence that was never asked how to clean it
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
    Then  the menu command "decisionTreeAll" is enabled
      And the menu command "decisionTreeAutoOnly" is enabled
