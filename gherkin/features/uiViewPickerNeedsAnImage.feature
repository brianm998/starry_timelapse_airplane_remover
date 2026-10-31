@uiViewPickerNeedsAnImage @ui @mac-gui @desktop
Feature: A view the frame has no image for cannot be chosen

  Q1 of the parity plan. The final frames option is there on a sequence nothing has been done to, greyed out; choosing it does nothing, and the
  original frames stay selected.

  Scenario: Choose the final frames of an unprocessed sequence
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
      And I click "view.final"
    Then  "view.original" is selected
      And "view.final" is not selected
