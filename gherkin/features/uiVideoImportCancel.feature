@uiVideoImportCancel @ui @mac-gui @desktop
Feature: Cancelling a video import leaves nothing behind

  S1 and S7 of the parity plan: Cancel on the loading screen of a video import stops ffmpeg, takes back the half-extracted frames folder, puts the
  start screen back and shows no error. (The gui used to let the decode run on to the end and leave the folder; the daemon behind the desktop
  client has always cancelled it.) The video is made from the copied sequence's frames (listed in an ffmpeg concat file, since the Windows ffmpeg build has no glob input) and looped to be long enough that its extraction is
  still going when Cancel is pressed; it is imported in the foreground (not "extract in the background"), which is the loading screen with a
  Cancel. The folder is waited for first, so that "gone" cannot be true only because it was never made.

  Scenario: Cancel during the extraction of a video's frames
    Given a fresh copy of the sequence {sequence}
    When  I start importing a long video of the copied sequence
    Then  the video's frames are being extracted
    When  I click "loading.cancel"
    Then  "startup.dropzone" is shown
      And "error.close" is not shown
      And the video's frames folder is gone
