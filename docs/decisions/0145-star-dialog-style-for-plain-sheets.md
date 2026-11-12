# 0145 — One shared star dialog style for the gui's plain sheets

Status: accepted (task #160, stage s150)

## Context

Several macOS gui sheets and popovers set no background and no colour scheme, so they came up on the
system window background (white in Light mode) with white-on-white or dark-on-white text. The styled
dialogs (`InfoDialogView`, `ProcessingSettingsView`, `KeypointDivisorStartupView`) use the dialog grey
with white text and the dark appearance. `KeypointDivisorStartupView` carried its own copy of that look.

## Decision

Add `starDialogStyle()` as a `View` extension in `gui/star/InfoDialogView.swift`:
`.background(Color.gray)`, `.foregroundColor(.white)`, `.environment(\.colorScheme, .dark)`.

- `.environment(\.colorScheme, .dark)` rather than `.preferredColorScheme(.dark)`: the latter propagates
  up to the presenting window, which would change the window's appearance.
- Applied at the outermost body of each plain sheet or popover, after its padding and frame, so the
  grey reaches the sheet's edges.
- Explicit colours inside the views are left alone; they read on the grey.

## Consequences

- Independent of the app-wide dark appearance: the test forces `.aqua` and still expects the grey.
- `AlignmentInfoOverlay` draws `AlignmentInfoContent` as a card over the processing modal. The content
  now paints the grey itself, so the overlay's former `Color(white: 0.22)` backing no longer shows.
  That is a visible change to the overlay, made because the overlay reuses the same body.
- The desktop client already matches; no Kotlin change.

## Alternatives rejected

- Setting `NSApp.appearance = .darkAqua` app-wide: a separate companion ticket, and it would also restyle
  system alerts and open panels.
- A new grey: the ticket keeps the gui's existing `Color.gray`.
