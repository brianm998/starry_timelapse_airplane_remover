@uiStartDuringRun @ui @mac-gui @desktop
Feature: A start while a run is going stops that run and takes its place

  L8 of the parity plan, settled by the owner (D: supersede). Re-Process Everything on frames 0, 1 and 3 to 18 starts a run over 0 to 18 (frame 2, in
  between, is not cleared, so it is left alone), and while it goes on (the processing screen lets the user look away from it, Preview)
  Re-Process Everything on frames 2 and 6 asks for another. The second takes the first's place: the first is stopped, so frame 18, which it had cleared and is
  the last it would have reached, is outside the second's range and is left unfinished, and frame 2 is run, so it has the decision tree's first answer
  where it had none decided (the frames the cli made have no group decided). The desktop used to answer the second start with success and do nothing, and frame 2 stayed as it was.
  The feature's steps race the engine, so the first run must outlast them. On the hosted Windows runner a first run over frames 0, 1 and 3 only was over in
  20 s (stard: 19:24:23 to 19:24:43), before the second start was clicked at 19:25:15 (the steps between took about 55 s there, a command-click alone 29 s),
  so nothing was superseded; and the second run, over one frame, took 8 s and was gone before "processing.modal is shown" polled it. Over frames 0, 1 and 3 to 18
  it was still not enough: in job 128893100181 the first run started at 23:50:40, frame 18 was complete at 23:52:34 (114 s for 19 frames), and the second
  start was clicked at 23:52:56 (its modal at 23:52:59), 22 s too late. stard's "all operations cancelled" at 23:52:59 came after the first run had ended; the
  daemon supersedes correctly. The sequence has only 19 frames, so the run cannot be made longer by range: "the processed copy processes one frame at a time"
  makes it slower per frame instead. On the hosted macOS runner a 4-frame first run finished in about 20 s: the same race. The checked frame is 18, not 0
  or 3: it is the last the first run would reach, so it stays unfinished only if that run was stopped. Starts from the processed sequence the cli made once.
  A fourth Windows run (job 129003406818, stard log) was a race again: the first run's frame 18 was complete at 07:02:04.2, the second start was clicked at 07:02:07.7
  and stard cancelled at 07:02:09.1, resetting only frames 2 and 17, so frame 18 had been written 3.5 s before anything could supersede it (the other attempt, job 128965364756:
  frame 18 at 04:51:03.6, second click 04:51:06.9). The steps between the starts took about 90 s there and the command-click of "grid.cell.17" alone 42 s, the grid
  scrolling to a far cell while the engine used every core. So the second selection is cells 2 and 6 (cell 6 is reachable on the small macOS screen, uiOpenWhileProcessing clicks it),
  frame 18 is still outside it, and "the processed copy processes one frame at a time" also gates the engine to one native operation, which leaves cores to the UI.

  Scenario: Re-process frames 2 and 6 during a run over frames 0, 1 and 3 to 18
    Given a processed copy of the sequence {sequence}
      And the processed copy processes one frame at a time
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
      And I command-click "grid.cell.6"
      And I right-click "grid.cell.6"
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
