# 0412: no allow-list for the Detailed tab

Cause: task #431, Kotlin Client red at 022d1691 (t249's English literals in `InfoDialog.kt`).
Choice: add nothing. t252 put the Detailed text in the catalogue (decision 0407), which removes the literals the test objected to. An earlier attempt allow-listed literals that no longer exist; that was reverted.
