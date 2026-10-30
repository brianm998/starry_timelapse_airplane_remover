package com.star.desktop.domain

/**
 * The playback speeds the Display section's picker offers, in frames per second: the gui's list (`gherkin/ui/vectors/constants.json` holds it, and a
 * test on each side checks it). The bottom strip's slower and faster buttons stepped through every rate from 1 to 90; the gui offers these.
 */
object PlaybackRates {
    val choices: List<Int> = listOf(1, 2, 3, 5, 10, 15, 20, 25, 30, 60, 90)
}
