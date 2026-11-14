# 0196: StarArtTest near-white edge failure (ticket #254)

Status: accepted (ticket #254)

Context: `Kotlin Client` failed on ubuntu-latest with Gradle's "Execution failed for task ':test'": `StarArtTest > cutoutsAndTilesHaveTransparentCorners(): art_horizon_auto: 1290 of 8631 edge pixels are near-white`. The test allowed 5% near-white edge pixels, but the robot's white-lavender armour is real paint on the soft edge (15% on art_horizon_auto), and `art_format_tiff16` has alpha 1 in its corners.

Decision: develop landed the fix for the same test while this ticket was open (25% share, fringe check only on checkerboard-cleaned slots, corner alpha <= 2). This branch dropped its own, stricter per-slot variant in the merge and keeps develop's version, so there is one rule, not two.

Consequence: the test file is unchanged from develop; only these notes remain from this ticket.

Batch #200 also failed on pipeline/tests/test_engine.py::test_a_landing_stage_goes_before_new_work: the test dropped its placeholder landing waiter before the real landing stage had registered, so under load new work could take the only unit. The test now waits for registration first (test-only race, no product change).
