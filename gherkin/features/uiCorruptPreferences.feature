@uiCorruptPreferences @ui @mac-gui @desktop
Feature: A preferences file the app cannot read is left as it is, with a copy beside it

  M1 of the parity plan. When the preferences file is there but is not valid JSON (a hand edit, a half-written file), saving the defaults over it
  would destroy whatever it held, so neither client writes to it, and each keeps a copy of it beside it, named after it with ".undecodable". Opening
  a sequence adds it to the recent list, which is the write that would have overwritten it.

  Scenario: Open a sequence with an unreadable preferences file
    Given the preferences file is the fixture "unreadable"
      And a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
    Then  the preferences file has an undecodable copy of the fixture "unreadable"
      And the preferences file is still the fixture "unreadable"
