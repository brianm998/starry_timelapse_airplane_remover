# 1230: the gui status count lines never re-render (observers were not @Observable)

## Problem
Run 46041252820 (commit f006df96): `Gherkin/mac gui (macos-15) · ui` fails in `uiOutlierClickKeeps` and
`uiOutlierClickUndecided`: `status.keep` stays at "0 will keep" for 90 s instead of "1 will keep".
Decision 1060 (frame lines) was disproved and 1176 (arrow layering) is unproven.

## Hypothesis (not confirmed)
The xcresult cannot be read offline, so this is a cause grounded in code, not a proven one.
`BottomRightView` reads `frameView.frameObserver.numberOf*Outliers`, but `FrameObserver` was a plain
`@MainActor class`. `FrameViewModel.frameObserver` is observed only as a reference, so
`FrameAirplaneRemover.updateCombineSubjects()` (via `markAsChanged()` after a click) setting new counts
never invalidated the view. `OutlierRemovalObserver.shouldRemove` had the same gap.

## Change
`FrameObserver` and `OutlierRemovalObserver` are `@Observable` (StarCore already uses it in
`FrameGraphViewModel`). Public API unchanged. `FrameObserverObservationTests` proves a count change or
`set(shouldRemove:)` fires `withObservationTracking`.

No Kotlin, proto, daemon-mapping or localization change: no user-visible string, behaviour or layout
changes, and the desktop leg is green (it reads counts from daemon messages).

## If it is still red
Diagnose from the runner's click evidence (`GuiFeatureRunner.describeProbeClick` /
`describePostClick`, already in place), not another guess. Final proof is CI only (ui tests never run here).
