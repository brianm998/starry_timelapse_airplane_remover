# 0196: StarArtTest holds each art slot to its own measured near-white edge share

Status: accepted (ticket #254)

Context: `Kotlin Client` failed on ubuntu-latest with `StarArtTest > cutoutsAndTilesHaveTransparentCorners(): art_horizon_auto: 1290 of 8631 edge pixels are near-white`. The test counts partly transparent pixels with min channel > 225 as leftover checkerboard fringe and allowed one flat 5% for every checked slot (the three checkerboard-cleaned cutouts and all tiles). The art added by the second batch is genuinely light on its soft edge (the robot's white-lavender armour, the white glyphs on the step tiles), so nine slots exceed 5%, and `art_format_tiff16` has alpha 1 in its four corners (blur residue, invisible). Exporter tuning (erode 1-4, tolerance 0.25-0.35) did not reduce the counts: the light pixels are paint, not fringe.

Decision: keep the check on every cleaned slot and every tile, but give it a per-slot baseline (`LIGHT_EDGE_BASELINE`, measured from the exported PNGs: horizon_auto 15%, process_gear 16%, waiting 20%, mode_selective 6%, step_align 27%, step_horizon 15%, step_merge 17%, step_render 38%, step_review 20%) plus a 5-point margin. Every other slot stays at 5%. The corner check stays at alpha 0 except `art_format_tiff16` (alpha <= 1). No coverage is removed and no slot gets a looser limit than its own measurement.

Consequence: a leftover checkerboard fringe on any slot raises that slot above its own baseline and fails; a replaced master needs its baseline updated deliberately.
