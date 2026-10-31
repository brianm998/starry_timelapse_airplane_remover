@uiNumberFields @ui @mac-gui @desktop
Feature: A number field commits on Return, puts the old number back on Esc, and gives the keyboard back either way

  Q9 and P3 of the parity plan. One rule for the number fields of both clients: Return takes what was typed, Esc leaves the number as it was, and
  both give the keyboard back to the frame, so that the arrow keys that follow move the frame and are not swallowed by the field. The field here is
  the static merge's neighbour count in the right panel, which a frame can be given its own number for.

  Scenario: Commit one number and abandon another
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
      And I type "7" into "right.neighbors"
    Then  "right.neighbors" has the keyboard
    When  I press "return"
    Then  "right.neighbors" holds the number 7
      And "right.neighbors" does not have the keyboard
    When  I type "9" into "right.neighbors"
    Then  "right.neighbors" has the keyboard
    When  I press "escape"
    Then  "right.neighbors" holds the number 7
      And "right.neighbors" does not have the keyboard
