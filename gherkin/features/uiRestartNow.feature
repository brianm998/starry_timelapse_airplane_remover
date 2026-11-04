@uiRestartNow @ui @mac-gui @desktop
Feature: Restart Now picks an interrupted run back up without the left-off panel and ends with the render question

  S2 and S3 of the parity plan (`ResumedRun.showsProgressPanel` and `asksAboutRenderingAtTheEnd` on the desktop; the gui's `restartProcessing`).
  A run that was killed leaves a run marker beside the sequence, and the next start of the app reports it in a critical alert that offers Restart
  Now when the marker names a config.json that still exists. Choosing it resumes the run: the panel that says where this sequence left off is not
  shown over it (the user has just said to go on), and when the run is done the app asks whether to render the video, as a run started from the
  pre-processing prompt does. The marker is planted for the processed copy the cli made once, with a pid no process has and an old heartbeat, so
  it is abandoned; the runner removes it afterwards whatever the result. The render prompts are on in the scratch preferences. Only the end of
  the run is waited for: the fixture is a selective run, so what is left to do may finish before the processing screen is looked at.

  Scenario: Restart Now resumes a run the app finds interrupted
    Given a processed copy of the sequence {sequence}
      And a run was interrupted on the processed copy
    When  the app is started with no sequence
      And I click the label "ui.restart_now"
    Then  "prompt.post.cancel" is shown
      And "sequenceprogress.close" is not shown
