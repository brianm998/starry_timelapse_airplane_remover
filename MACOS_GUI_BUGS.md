# macOS GUI Bugs Found During the Kotlin Parity Audit

**Found:** 2026-10-13, while auditing the macOS SwiftUI client (`gui/star/`) against the Kotlin client
(see `KOTLIN_CLIENT_PARITY_PLAN.md`). These are defects in the **macOS** client. They are recorded here so they can be
fixed separately, and so that nobody ports them into the Kotlin client. Each was confirmed by reading the code at
`develop` commit `d6ff8ade`; none has been fixed yet.

All paths are relative to the repo root.

---

## 1. The "Pixel threshold" setting does nothing

- **Where:** `gui/star/ImageSequenceViewModel.swift:1691` (`var pixelThreshold: Double = 1.2`), edited by the
  Pixel threshold row in `gui/star/ProcessingSettingsView.swift` (around line 880).
- **What's wrong:** every other settings property on the view model has a `didSet` that copies the value into the
  `Config` and calls `config.update(...)`. `pixelThreshold` has no `didSet`, so the value the user types never reaches the
  config or the engine.
- **Effect:** the row is decorative; changing it has no effect on processing.
- **Fix options:** wire it through to the config the same way as its neighbours (check whether `Config` still has a
  matching field — the daemon audit found `pixelThreshold` is internal on `Config`), or remove the row.

## 2. Two decimal settings can't be typed as decimals

- **Where:** `gui/star/ProcessingSettingsView.swift:1228-1238` (homography smoothing ε, range 0–10, default 0.01) and
  `:1743-1753` (horizon spike max deviation fraction, range 0.001–0.5, default 0.02).
- **What's wrong:** both `EditableNumberView`s omit `allowDecimal: true`. `EditableNumberView.commitIfValid()`
  (`gui/star/EditableNumberView.swift:110-127`) then filters the text to digits only, so "0.05" becomes "005" → 5.
- **Effect:** ε can only be set to whole numbers (losing its useful range), and the spike deviation fraction can never be
  set at all (every whole number is ≥ its 0.5 maximum, so the edit silently reverts).
- **Fix:** pass `allowDecimal: true` on both.

## 3. `EditableNumberView`'s upper bound is exclusive

- **Where:** `gui/star/EditableNumberView.swift:117-119` — `newVal >= minValue, newVal < maxValue`.
- **What's wrong:** the maximum value itself is rejected (e.g. 255 when the help text says "Max value is 255"), and the
  edit silently reverts.
- **Fix:** use `newVal <= maxValue`, and check each call site's `maxValue` still means what its help text says.

## 4. Custom frame-rate field in Render Video reads the wrong string

- **Where:** `gui/star/RenderVideoSheetView.swift:215-226`.
- **What's wrong:** the custom frame rate `TextField` binds `$frameRateString`, but its `.onSubmit` parses
  `viewModel.trashLevelString` instead.
- **Effect:** typing a custom frame rate and pressing Return applies whatever the trash level string holds (or nothing),
  so custom fps entry is broken.
- **Fix:** parse `frameRateString`.

## 5. Detection-type picker stays disabled after switching to Selective

- **Where:** `gui/star/ProcessingSettingsView.swift:1842` (`.disabled(autoPreservationMode == .no)`), with
  `autoPreservationMode` initialised from `viewModel.cleanMethod.usesOutliers` at `:426-430`.
- **What's wrong:** if the sheet opens on Automatic with auto-preservation No, then the user switches the clean method to
  Selective, `autoPreservationMode` stays `.no`, so the detection-type picker stays disabled even though Selective uses
  outliers and needs a detection type.
- **Fix:** disable the picker based on the effective clean method (`!cleanMethod.usesOutliers`), not on
  `autoPreservationMode` alone.

## 6. "Show info" / "Hide info" skip the neighbourhood-size row

- **Where:** `gui/star/ProcessingSettingsView.swift:277-415` (`showAll` / `hideAll` / `addSpacer`).
- **What's wrong:** the brightness-refinement neighbourhood-size row's info toggle isn't included in the show-all /
  hide-all lists or the spacer logic.
- **Effect:** "Show info" leaves that one row's help hidden (and "Hide info" leaves it open if it was opened by hand).
- **Fix:** add its toggle to the three lists.
