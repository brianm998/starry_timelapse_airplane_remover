# star

## Localization

Every user-visible string lives in the catalogue in
`StarCore/Sources/StarCore/Resources/Localizations/` (see `i18n/README.md`).

**English text in a non-English table is not OK.** `en.json` is the only file that may hold
English. Whenever you add or change a key, write a real translation into *every* other
`<code>.json` in the same change — never copy the English value in as a placeholder, and never
leave a new key to be translated "later". At runtime a missing key falls back to English
silently, and a value identical to English looks like a translation to every test, so nobody
will notice but the user who reads that language.

- Translate prose, labels, help text and errors into the table's own language and script.
- Reuse the terminology that table already uses for *frame*, *horizon*, *alignment*,
  *homography*, *neighbor*, etc., so the app reads consistently.
- Keep placeholders (`{0}`, `{1}`) and `\n` breaks; reordering placeholders is fine, adding or
  dropping one is not.
- The only values that may match English are ones that genuinely are the same in that language:
  the product name `star`, international acronyms and format names (GPU, CPU, JPEG, TIFF, fps),
  and pure-placeholder/punctuation strings.
  The `ui.<camelcase>` debug feature names (`ui.maxbrightness`, …) are identifiers and stay
  as they are.
- Check with `i18n/check.py` before finishing. Its "same as English" count per language sits at
  roughly 40 (the exceptions above); if it rises, look at what you added.

## Swift and Kotlin clients change together

The macOS gui (`gui/`, SwiftUI) and the desktop client (`star-desktop/`, Kotlin/Compose) are two
front ends to the same program. A user-facing change to one — a screen's wording, layout,
colours, buttons, estimates, dialogs — is made to the other in the same change, with the same
behaviour and the same catalogue keys, and each side's tests updated. Don't ship one and leave
the other "for later"; if a platform genuinely cannot do something, say so in the change.
