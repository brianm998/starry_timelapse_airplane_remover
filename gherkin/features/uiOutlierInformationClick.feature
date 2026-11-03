@uiOutlierInformationClick @ui @mac-gui @desktop
Feature: A click with the Information tool lists the group and leaves its decision alone

  E3 of the parity plan. The Information tool is for looking: a click on a group puts it in the outlier information window, and the group keeps the
  decision it had. (The gui used to treat the click as the toggle for a group that had no decision and marked it for removal.) The processed frame
  starts with groups nobody has decided (selective leaves them to the user): one click on a group with the Information tool opens the outlier
  window, and there is still no group to remove or to keep. Starts from the processed sequence the cli made once.

  Scenario: Look at an undecided group
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
    Then  the "outlier" window is not open
      And "status.remove" says "0 will remove"
      And "status.keep" says "0 will keep"
    When  I press "8"
      And I click "outlier.first"
    Then  the "outlier" window is open
      And "status.remove" says "0 will remove"
      And "status.keep" says "0 will keep"
