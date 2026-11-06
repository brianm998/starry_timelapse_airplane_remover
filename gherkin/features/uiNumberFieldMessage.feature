@uiNumberFieldMessage @ui @mac-gui @desktop
Feature: A number field says what it takes while the typed text is not a number it will take

  P5 of the parity plan. Both clients mark text a number field will not take and say what it takes, in the catalogue's words, under the field; the
  message goes when the text is a number the field takes. The red cannot be read through accessibility, so this asserts the words. The field is
  the Alignment tab's Max keypoints, which takes a whole number from 4 to 10000.

  Scenario: Text that is not a number gets the message and a number takes it away
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.advanced"
      And I click "settings.tab.alignment"
      And I type "abc" into "settings.alignment.maxkeypoints"
    Then  "settings.alignment.maxkeypoints.message" says "Enter a whole number from 4 to 10000"
    When  I type "50" into "settings.alignment.maxkeypoints"
    Then  "settings.alignment.maxkeypoints.message" is not shown
