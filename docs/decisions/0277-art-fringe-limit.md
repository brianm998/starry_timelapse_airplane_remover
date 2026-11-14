# 0277: No per-slot fringe limits; use develop's shared one

`StarArtTest` failed on art_horizon_auto (1290 of 8631 edge pixels near-white); raising `erode` did not help, so those pixels are the painted glow, not leftover checkerboard.

Decision: keep develop's shared `LIGHT_EDGE_SHARE = 0.25` (and `CORNER_ALPHA_MAX = 2`) from batch #197 rather than a per-slot map. It covers every measured slot (6-20%) and a real checkerboard fringe would sit far above it. The art stays untouched.
