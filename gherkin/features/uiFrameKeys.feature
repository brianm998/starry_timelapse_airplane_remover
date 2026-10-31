@uiFrameKeys @ui @mac-gui @desktop
Feature: The arrow keys and b and f move through the frames

  Both clients move through the sequence with the keys: right goes to the next frame, b to the first and f to the last. The frame number
  below the picture says which, counting from 0.

  Scenario: Step forward, then jump to the first and the last frame
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
    Then  "frame.number" says "frame 0"
    When  I press "right"
      And I press "right"
    Then  "frame.number" says "frame 2"
    When  I press "b"
    Then  "frame.number" says "frame 0"
    When  I press "f"
    Then  "frame.number" says "frame 18"
