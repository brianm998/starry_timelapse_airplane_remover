@uiStartDuringRun @ui @mac-gui @desktop
Feature: A start while a run is going stops that run and takes its place

  L8 of the parity plan, settled by the owner (D: supersede). Re-Process Everything on frames 0, 1 and 3 to 18 starts a run over 0 to 18 (frame 2, in
  between, is not cleared, so it is left alone), and while it goes on (the processing screen lets the user look away from it, Preview)
  Re-Process Everything on frames 2 to 17 asks for another. The second takes the first's place: the first is stopped, so frame 18, which it had cleared and is
  the last it would have reached, is outside the second's range and is left unfinished, and frame 2 is run, so it has the decision tree's first answer
  where it had none decided (the frames the cli made have no group decided). The desktop used to answer the second start with success and do nothing, and frame 2 stayed as it was.
  Both runs are long, about 18 frames, because the feature's steps race the engine. On the hosted Windows runner the first run, over frames 0, 1 and 3 only,
  was over in 20 s (stard: 19:24:23 to 19:24:43), before the second start was clicked at 19:25:15 (the steps between took about 55 s there, a command-click
  alone 29 s), so nothing was superseded; and the second run, over one frame, took 8 s (19:25:18 to 19:25:26) and was gone before "processing.modal is shown"
  polled it, which timed out after 90 s. The daemon supersedes correctly (it logs "all operations cancelled"). On the hosted macOS runner the two starts were 22 s
  apart and both modals were seen, but frame 3 still read "frame is complete" because a 4-frame first run finishes in about 20 s: the same race. The checked frame is 18, not 0
  or 3: it is the last the first run would reach, so it stays unfinished only if that run was stopped. Starts from the processed sequence the cli made once.

  Scenario: Re-process frames 2 to 17 during a run over frames 0, 1 and 3 to 18
    Given a processed copy of the sequence {sequence}
    When  I open the processed copy
      And I make the window large
      And I click "sequenceprogress.close"
      And I click "mode.grid"
      And I click "grid.cell.0"
      And I shift-click "grid.cell.18"
      And I command-click "grid.cell.2"
      And I right-click "grid.cell.18"
      And I click the label "ui.re_process_everything"
    Then  "processing.modal" is shown
    When  I press "return"
      And I click "mode.grid"
      And I click "grid.cell.2"
      And I command-click "grid.cell.17"
      And I right-click "grid.cell.17"
      And I click the label "ui.re_process_everything"
    Then  "processing.modal" is shown
    When  I press "return"
      And I click "mode.edit"
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
