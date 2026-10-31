@uiDecisionsSurviveClose @ui @mac-gui @desktop
Feature: A decision made just before Close is still there when the sequence is opened again

  L3 of the parity plan. The gui queued a frame's decisions for saving only when the user left the frame, so Close straight after an edit lost it. A
  decision is the frame's whether or not the user has left it: Remove All, Close at once (and answer the question about work in progress, if there is
  one), open the sequence again from the recent list (past the panel that says where it left off, and in edit mode), and the frame has none to keep.
  Keep All goes first so that Remove All has something to change whatever the frame started with.

  Scenario: Remove every group of a frame, close at once, open it again
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I click "sequenceprogress.close"
      And I click "mode.edit"
      And I choose the menu command "keepAll"
      And I choose the menu command "removeAll"
    Then  "status.keep" says "0 will keep"
    When  I choose the menu command "closeSequence"
      And I confirm closing if it is asked
      And I click "startup.recent.open"
      And I click "sequenceprogress.close"
      And I click "mode.edit"
    Then  "status.keep" says "0 will keep"
