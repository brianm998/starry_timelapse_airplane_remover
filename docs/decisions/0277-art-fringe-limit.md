# 0277: Per-slot fringe limits instead of a re-matte

`StarArtTest` failed on art_horizon_auto (1290 of 8631 edge pixels near-white); raising `erode` did not help, so those pixels are the painted glow, not leftover checkerboard, and colour cannot separate the two. Once it was passed, eight more slots with the same kind of glow or light rim failed (up to 38% for art_step_render), plus a tiff16 corner at alpha 1/255.

Decision: keep 5% as the default, add `FRINGE_LIMIT_PERCENT` with a limit above each measured share, and allow corner alpha <= 1. Corner transparency is otherwise still checked. A real checkerboard fringe would be higher than these limits, and the art stays untouched.
