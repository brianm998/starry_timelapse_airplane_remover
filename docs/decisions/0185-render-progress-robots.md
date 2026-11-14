# 0185: a fitting size on the generated ArtImage

Slots draw only at their own display size (done is 116x120), but the reopen panel wants it at 64 and the render views at 96. `ArtImage` gains an optional `fitting` side that scales the slot so its longer side matches, keeping the aspect. Without it behaviour is unchanged. It is in `art/export.py`, so both generated files carry it and no caller does its own arithmetic. The render progress robot sits above the text so the bar keeps its width.
