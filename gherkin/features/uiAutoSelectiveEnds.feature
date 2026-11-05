@uiAutoSelectiveEnds @ui @mac-gui @desktop
Feature: A run in Automatic with Selective Auto Clean ends with every frame complete

  L5 of the parity plan. Automatic removal with the auto selective switch on used to leave frames at "creating removal mask" for good, so the run never
  reached its end (a StarCore fix found by a real daemon run). The feature starts such a run from the startup questions and waits for the progress line to
  read every frame complete and the run idle: a frame left unfinished stalls it, which fails the wait. The run is the whole committed sequence, on both
  clients, with no step to finish frames by hand.

  Scenario: Automatic with Selective Auto Clean finishes every frame
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence
      And I click "startup.horizon.no"
      And I click "startup.moving.static"
      And I click "startup.removal.autoselective"
    Then  "startup.removal.autoselective" is on
    When  I click "startup.removal.start"
    Then  "prompt.pre.no" is shown
    When  I click "prompt.pre.no"
    Then  "processing.modal" is shown
    When  I press "return"
      And I click "mode.edit"
      And I wait for processing to finish
