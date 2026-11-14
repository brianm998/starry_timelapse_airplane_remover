# 0302: Processing complete shows the frame on screen, before and after

The frame is the one on screen, not the one with most removed: per-frame removal counts do not exist in the default
automatic mode. gui draws `.original` and `.final` previews (240 x 160, aspect fit); desktop uses `framePicture`
with `VIEW_ORIGINAL` and `VIEW_PROCESSED`, each at most 240 x 160 dp (shrinking to fit the 520 dp card), and a
16 dp arrow drawn in code. No new strings, so no catalogue change.
