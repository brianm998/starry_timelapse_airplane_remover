# 0184: trouble and waiting art

- The waiting robot (`art_waiting`, with its "zzz" over the dog) stays in its slot until the art is replaced.
- The Outlier empty window is gui-only; the desktop client has no such state.
- Empty windows scale the waiting art down (max 160 pt) rather than clip it; the Alignment window's `emptyStateArt` returns it exactly when `emptyState` has lines, tested against `gherkin/ui/vectors/alignmentWindow.json` in both clients.
- The gui's NSAlerts use `art_hold_on` as `alert.icon`; the in-window overlays and the desktop's ConfirmCloseOverlay draw it at 80 pt.
- No strings are added.
