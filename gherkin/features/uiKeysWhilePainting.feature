@uiKeysWhilePainting @ui @mac-gui @desktop
Feature: Under the horizon painter the frame keys answer and the mode keys do not

  M4 of the parity plan. While the painter is open the arrow keys still move through the frames (and ask "Change frame?" once paint has started),
  and the keys that change the mode do nothing: switching away would leave the painter behind.

  Scenario: Move through the frames and try a mode key
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
      And I choose the menu command "paintHorizon"
      And I press "right"
    Then  "frame.number" says "frame 1"
    When  I press "left"
    Then  "frame.number" says "frame 0"
    When  I press "g"
    Then  "mode.grid" is not selected
      And "mode.edit" is selected
