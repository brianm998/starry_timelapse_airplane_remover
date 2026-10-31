@uiSharedPreferences @ui @mac-gui @desktop
Feature: A preference a client does not know is kept when it saves

  M2 of the parity plan. The two clients share one preferences file, and each has keys the other does not (the desktop's outlier table columns, for
  one). A client saves only the keys it changed, so what the other wrote is still there afterwards. Opening a sequence adds it to the recent list,
  which is a save.

  Scenario: Open a sequence with a key of the other client in the preferences
    Given the preferences file is the fixture "foreignKey"
      And a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
    Then  the preferences file lists 1 recent sequences
      And the preferences file still has the key "outlierTableColumns"
