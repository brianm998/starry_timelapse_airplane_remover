# 0285: clamp edge alpha per slot in the art generator

StarArtTest requires cutouts and tiles to have transparent corners and at most 5% near-white partly-transparent pixels.
Resampling left faint and near-opaque alpha tails on a handful of slots. Decision: art/export.py takes `snap` (alpha below it
becomes 0) and `snap_opaque` (alpha at or above it becomes 255), applied after sizing, enabled per slot in art/slots.json.
The test and its threshold are unchanged. The gui and desktop use the same regenerated PNGs.
