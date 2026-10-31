@uiOutlierMultiClick @ui @mac-gui @desktop
Feature: A click with the Multi tool changes the group's decision, unless Multi Choice is on

  E2 of the parity plan, settled by the owner (D3): with the "Multi Choice" switch off, a click on a group with the Multi tool is a plain click, so it
  flips the group's decision as the Remove and Keep tools do; it opens the multi-choice sheet only when the switch is on. The desktop used to open the
  sheet on every Multi click. With every group of the frame kept (Keep All), one click on a group with the Multi tool makes it one to remove, and no
  sheet comes up in its way. Starts from the processed sequence the cli made once, so the frame has groups.

  Scenario: Keep every group, then click one with the Multi tool
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I choose the menu command "keepAll"
    Then  "status.remove" says "0 will remove"
    When  I press "7"
      And I click "outlier.first"
    Then  "status.remove" says "1 will remove"
