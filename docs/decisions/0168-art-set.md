# 0168: one art set generated from `art/slots.json`

Both clients get the same 32 slots under the same names. `art/export.py` is the only writer of the
imagesets, the desktop resources and both `StarArt` loaders; `--check` proves nothing drifted.

- Masters are committed downscaled (4x the display box, to survive trimming), not the 70 MB originals.
- Backgrounds are removed at export, not in the masters, so a better matte can replace the current one without a re-download.
- A slot that needs a different matte sets `tolerance`, `spread` or `erode` in `slots.json` (`art_horizon_auto`
  does: its glow was painted over the checkerboard).
- Scenes are JPEG q85; everything else is PNG. The desktop resource is the 2x image.
- `ArtImage` is decoration: hidden from accessibility, so art adds no strings.
