# Star icons

The small interface icons shared by the macOS client (`gui/`) and the desktop client (`star-desktop/`). `manifest.json` lists every icon with its size on screen, how it is tinted and where it goes.

## How they are drawn

- Most icons are on a 24-unit grid with a 2-unit stroke and round caps and joins.
- The exceptions are the filmstrip badges (12-unit grid), the frame range pickers (36 × 24) and the cursors (40 units).
- They use only plain shapes and paths, with no `<style>`, `<use>`, masks or clip paths, so that Xcode's asset compiler and Skia have nothing unusual to deal with.
- No icon contains letters or numbers. Labels come from the string catalogue.

## Tint

Everything except `tool_*` and `cursor_*` is one colour, drawn in `currentColor`, and the client decides the colour at draw time. That is what lets one file serve the enabled, disabled and selected states. `tint` in `manifest.json` says which treatment each group gets:

| `tint` | Treatment |
| --- | --- |
| `neutral` | Light grey, in the main window and around the frame |
| `brand` | The board's gradient, `#6986DD` at the lower left to `#9C89F0` at the upper right, in dialogs |
| `app` | A colour the client picks per state, such as red, orange or green on the filmstrip badges |
| `tray` | A system template image |
| `colour` | Keeps its own colours and a dark keyline, because red and green carry meaning |

## Cursors

`cursor_*` icons are on a 40-point canvas, the same as the cursors they replace, and keep the same click points: (15, 15) for crosshairs and (9, 5.67) for pointing hands. The desktop client builds its cursors through `ImageIO`, which cannot read SVG, so those need exporting to PNG.
