@uiOpenWhileProcessing @ui @mac-gui @desktop
Feature: File > Open while a run is going asks first

  M3 of the parity plan: File > Open Image Sequence, Open Video and Resume from config.json replace the sequence that is open, so with a run going
  they ask the work-in-progress question, with "Stop and Open" as the red button, before the file chooser is shown. Cancel keeps the run, and
  Stop and Open goes on to the chooser. The chooser is the system's own and cannot be driven, so the runner answers it with the processed copy's
  folder (gui: `-StarUITestChoosePath`; desktop: the `star.ui.choosePath` property), which leads on to the question of where its files go.
  The run is the start of `uiStartDuringRun`, longer: Re-Process Everything on frames 0 and 6 of the processed sequence the cli made once: the run spans 0 to 6 (the frames between are run, only not cleared), where on frames 0, 1 and 3 it
  was over before the feature's second Open, on a loaded machine, and then nothing is asked. Only the two ends are clicked: on the hosted macOS runner's small screen
  the grid shows about one cell, a cell below the fold (frame 7) takes a click that lands outside the grid, in the Dock, and the context menu never opens, and on
  the hosted Windows runner every UI step costs seconds, with the engine using every core.

  Scenario: Open Image Sequence during a run, cancelled and then confirmed
    Given a processed copy of the sequence {sequence}
      And the file chooser answers with the processed copy
    When  I open the processed copy
      And I make the window large
      And I click "sequenceprogress.close"
      And I click "mode.grid"
      And I click "grid.cell.0"
      And I command-click "grid.cell.6"
      And I right-click "grid.cell.6"
      And I click the label "ui.re_process_everything"
    Then  "processing.modal" is shown
    When  I press "return"
      And I choose the menu command "openImageSequence"
    Then  "closeconfirm.confirm" reads "ui.stop_and_open"
    When  I click "closeconfirm.cancel"
    Then  "closeconfirm.confirm" is not shown
      And "sequencelocation.open" is not shown
      And the menu command "cancelProcessing" is enabled
    When  I choose the menu command "openImageSequence"
      And I click "closeconfirm.confirm"
    Then  "sequencelocation.open" is shown
