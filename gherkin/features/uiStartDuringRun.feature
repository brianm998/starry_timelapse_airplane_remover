@uiStartDuringRun @ui @mac-gui @desktop
Feature: A start while a run is going stops that run and takes its place

  L8 of the parity plan, settled by the owner (D: supersede). Re-Process Everything on frames 0, 1 and 3 to 18 starts a run over 0 to 18 (frame 2, in
  between, is not cleared, so it is left alone), and while it goes on (the processing screen lets the user look away from it, Preview)
  Re-Process Everything on frames 2 and 6 asks for another. The second takes the first's place: the first is stopped, so frame 18, which it had cleared and is
  the last it would have reached, is outside the second's range and is left unfinished, and frame 2 is run, so it has the decision tree's first answer
  where it had none decided (the frames the cli made have no group decided). The desktop used to answer the second start with success and do nothing, and frame 2 stayed as it was.
  The first run must still be going at the second start, and no speed can be relied on for that: on the hosted Windows runner the steps between the starts took
  minutes (a command-click alone up to a minute) and the first run's frame 18 was written before the second start was clicked, several times over, so nothing was
  superseded; the daemon was right each time. So the run does not race the steps: "the processed copy's run is held after its first frame" parks the merge of every
  frame but the first (StarCore's `MergeOp`, a `merge.hold` file in the working folder), so frame 18 cannot be written until "the held run is released", which is
  after the second start, and then only if the first run was not stopped by it. The checked frame is 18, not 0 or 3: it is the last the first run would reach, so it
  stays unfinished only if that run was stopped. "The processed copy processes one frame at a time" stays, to leave the cores to the UI. The second selection is
  cells 2 and 6 (cell 6 is reachable on the small macOS screen); the first's right-click is on cell 3, which keeps the grid near the top. Starts from the processed
  sequence the cli made once.

  Scenario: Re-process frames 2 and 6 during a run over frames 0, 1 and 3 to 18
    Given a processed copy of the sequence {sequence}
      And the processed copy processes one frame at a time
      And the processed copy's run is held after its first frame
    When  I open the processed copy
      And I make the window large
      And I click "sequenceprogress.close"
      And I click "mode.grid"
      And I click "grid.cell.0"
      And I shift-click "grid.cell.18"
      And I command-click "grid.cell.2"
      And I right-click "grid.cell.3"
      And I click the label "ui.re_process_everything"
    Then  "processing.modal" is shown
    When  I press "return"
      And I click "mode.grid"
      And I click "grid.cell.2"
      And I command-click "grid.cell.6"
      And I right-click "grid.cell.6"
      And I click the label "ui.re_process_everything"
    Then  "processing.modal" is shown
    When  I press "return"
      And I click "mode.edit"
      And the held run is released
      And I wait for processing to stop
      And I click "mode.grid"
      And I click "grid.cell.2"
      And I click "mode.edit"
    Then  "frame.number" says "frame 2"
      And "status.keep" stops saying "0 will keep"
    When  I click "mode.grid"
      And I click "grid.cell.18"
      And I click "mode.edit"
    Then  "frame.number" says "frame 18"
      And "status.state" stops saying "frame is complete"
