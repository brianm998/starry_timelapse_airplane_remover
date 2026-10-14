# macOS GUI Bugs Found During the Kotlin Parity Audit

The six bugs first listed here were fixed on `develop` (and this file was removed there). These three were found afterwards, while the
Kotlin client's multi-frame sheets and outlier window were written against the macOS ones. They are recorded so they can be fixed
separately, and so that nobody ports them into the Kotlin client. Paths are relative to the repo root.

## 1. The multi-select / multi-choice sheets show raw catalogue keys for the frame choices

- **Where:** `gui/star/MultiSelectSheetView.swift:5-14` (`MultiSelectionType.localizedName`), shown as the radio list in both
  `MultiSelectSheetView` and `MultiChoiceSheetView`.
- **What's wrong:** `localizedName` looks up `multi_selection.\(rawValue)`, but the raw values are English phrases
  ("all frames", "from this frame to the end", …) while the catalogue entries are keyed by case name
  (`multi_selection.all`, `multi_selection.allAfter`, `multi_selection.allBefore`, `multi_selection.someAfter`,
  `multi_selection.someBefore`). A missing key comes back as the key itself (`StarLocalization.string(forKey:)`).
- **Effect:** the radio rows read `multi_selection.all frames` and so on, in every language.
- **Fix:** look up by case name (give the enum a `key` or make the raw values the case names). The other two pickers in those
  files (`multi_removal.*`, `multi_paint.*`) already match.

## 2. "From this frame to the end" says it covers one frame too many

- **Where:** `gui/star/MultiSelectSheetView.swift:77` and `gui/star/MultiChoiceSheetView.swift:58`
  (`let numFrames = frames.count - currentIndex + 1`).
- **What's wrong:** frames `currentIndex ... count - 1` are `count - currentIndex` frames, not one more. The sentence
  ("… in N frames from frame X to the end") is wrong by one. (`.allBefore` is right: `currentIndex + 1`.)
- **Fix:** drop the `+ 1`.

## 3. The outlier window's "classification score" column toggle is labelled "NeighborLineDistanceScore"

- **Where:** `gui/star/OutlierWindowView.swift` (the last `Toggle` in `openTableControls`:
  `Toggle(localized("ui.neighborlinedistancescore"), isOn: $outlierWindowViewModel.showClassificationScore)`).
- **What's wrong:** copy-paste of the line above it, so the chooser lists "NeighborLineDistanceScore" twice and the classifier's
  score column has no toggle of its own to find.
- **Fix:** give it a label of its own (the Kotlin client added `ui.classification_score`).
