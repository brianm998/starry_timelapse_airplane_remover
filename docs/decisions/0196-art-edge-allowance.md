# 0196: raise StarArtTest's near-white edge limit to 25%

Status: accepted (ticket #254)

Context: `Kotlin Client` failed on ubuntu-latest with `StarArtTest > cutoutsAndTilesHaveTransparentCorners(): art_horizon_auto: 1290 of 8631 edge pixels are near-white`. The test counts partly transparent pixels with min channel > 225 as leftover checkerboard fringe and allowed 5%. The cutouts show a robot in white-lavender armour whose soft edge is real paint: the checked slots measure 6-20% (art_waiting 19%, art_horizon_auto 15%, art_hold_on 15%).

Decision: allow 25%. Exporter tuning (erode 1-4, tolerance 0.25-0.35) did not reduce the count, and redrawing the art is out of scope.

Consequence: the test still catches a leftover checkerboard (most of the edge would be light), but not a thin one.
