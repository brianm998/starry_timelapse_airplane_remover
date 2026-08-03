# star localization catalogue

The tables themselves live in `StarCore/Sources/StarCore/Resources/Localizations/`; this
directory holds the tooling and this document, which must stay *out* of that directory —
SwiftPM copies it wholesale into every shipped client.

Run `i18n/check.py` to validate the catalogue.

Every user-visible string in every star client, in every language star ships.

## Layout

| file | what it is |
|---|---|
| `languages.json` | the languages star ships, in the order every picker shows them |
| `en.json` | **the source of truth.** English, and the full set of keys |
| `<code>.json` | one translation table per language, with exactly `en.json`'s keys |

## Who reads this directory

- **Swift** — `StarCore/Localization/StarLocalization.swift` loads it from `Bundle.module`.
  `star` (cli), `stard` (daemon) and the macOS gui all get it through StarCore, so there is
  nothing per-client to wire up.
- **Kotlin** — `star-desktop`'s `processResources` copies these files into the jar at `/i18n/`,
  and `com.star.desktop.i18n.Strings` reads them from there. The catalogue is **not** duplicated
  in the Kotlin source tree; this directory is the only copy in git.

## Format

Flat JSON, one object, `"key": "value"`. No nesting, no comments (it is parsed by
`JSONDecoder` and by Gson, and neither accepts them).

Placeholders are positional: `{0}`, `{1}`, … A translator may **reorder** them —
`"{1} of {0}"` is fine and is the whole reason they are numbered — but must not add or drop
one. `LocalizationTests.testPlaceholdersSurviveTranslation` fails the build if a translation's
placeholder set differs from English's.

## Adding a string

1. Add the key and the English text to `en.json`.
2. Add the same key to all the other tables.
3. Call it: `localized("your.key")` or `localized("your.key", someValue)` — the same spelling in
   Swift and in Kotlin.

`LocalizationTests` fails if step 2 is skipped, which is deliberate: at runtime a missing key
silently falls back to English, so the test is the only thing that would ever notice.

## Adding a language

1. Add a row to `languages.json` (`code` is BCP-47, `nativeName` is the language's name *in that
   language* — a picker showing English names is no use to someone who cannot read English).
2. Add `<code>.json` with every key from `en.json`.

Nothing else. Both clients read the manifest at startup, and both language menus are built
from it.

## Key naming

| prefix | what it covers |
|---|---|
| `ui.*` | anything on screen in either gui |
| `cli.*` | `star`'s `--help` text and terminal output |
| `warning.*` | `StarWarning` titles, messages and suggestions |
| `run_marker.*` | the crash / interrupted-run report |
| `frame_state.*`, `operation.*`, `alignment_state.*` | the progress vocabulary, shared by the cli progress bars and the gui panels |
| `tool.*`, `multi_*`, `scene_type.*`, `camera_motion.*`, `interaction_mode.*`, `fast_advancement.*` | enum display names |
| `language.*`, `menu.*`, `severity.*`, `duration.*`, `progress.*` | small shared vocabularies |

## Known limitation: plurals

The tables are flat strings, so there is no CLDR plural-category support. Where English needs
two forms the catalogue carries two keys (`cli.errors.finished_one` /
`cli.errors.finished_many`) and the caller picks. Languages with more than two plural forms —
Arabic, Polish, Russian, Ukrainian, Czech — cannot express all of them this way; their
translations use count-neutral phrasing instead, which is correct for every count even though
it is not always the most natural wording. Proper plural support would mean a value being an
object rather than a string, in both runtimes.
