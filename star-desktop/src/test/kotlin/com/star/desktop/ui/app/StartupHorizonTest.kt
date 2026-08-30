package com.star.desktop.ui.app

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Verifies the moving-horizon startup frame spacing matches macOS
 * `ImageSequenceViewModel.calculateFrameIndices` exactly (first = 0, last = total-1, evenly spread).
 */
class StartupHorizonTest {

    @Test fun singleHorizonIsFirstFrame() {
        assertEquals(listOf(0), evenlySpacedFrameIndices(count = 1, total = 100))
    }

    @Test fun threeHorizonsSpanFirstMiddleLast() {
        assertEquals(listOf(0, 5, 9), evenlySpacedFrameIndices(count = 3, total = 10))
    }

    @Test fun fiveHorizonsAreEvenlySpaced() {
        // round(i * 99 / 4): 0, 24.75→25, 49.5→50, 74.25→74, 99
        assertEquals(listOf(0, 25, 50, 74, 99), evenlySpacedFrameIndices(count = 5, total = 100))
    }

    @Test fun countAtOrAboveTotalReturnsEveryFrame() {
        assertEquals((0 until 4).toList(), evenlySpacedFrameIndices(count = 4, total = 4))
        assertEquals((0 until 4).toList(), evenlySpacedFrameIndices(count = 9, total = 4))
    }

    @Test fun firstAndLastAreAlwaysEndpoints() {
        val idx = evenlySpacedFrameIndices(count = 7, total = 41)
        assertEquals(0, idx.first())
        assertEquals(40, idx.last())
        assertEquals(7, idx.size)
    }

    @Test fun degenerateInputsAreEmpty() {
        assertEquals(emptyList(), evenlySpacedFrameIndices(count = 0, total = 10))
        assertEquals(emptyList(), evenlySpacedFrameIndices(count = 3, total = 0))
    }

    // resuming a selection the last session did not finish
    // (macOS `ImageSequenceViewModel.startupHorizonResumeFrame`)

    /** The case it exists for: stopped after painting two of five. */
    @Test fun anUnfinishedSelectionResumesOnTheFrameItStoppedAt() {
        assertEquals(50, startupHorizonResumeFrame(listOf(0, 25, 50, 75, 99), 2, frameCount = 100))
    }

    @Test fun theFirstAndLastFramesOfASelectionBothResume() {
        assertEquals(0, startupHorizonResumeFrame(listOf(0, 25, 50, 75, 99), 0, frameCount = 100))
        assertEquals(99, startupHorizonResumeFrame(listOf(0, 25, 50, 75, 99), 4, frameCount = 100))
    }

    /** The static flow records one frame, so that it resumes by the same route as a moving one. */
    @Test fun aSingleFrameSelectionResumes() {
        assertEquals(42, startupHorizonResumeFrame(listOf(42), 0, frameCount = 100))
    }

    /** Never asked for, or asked for and finished: both leave the list empty. */
    @Test fun noRecordedSelectionDoesNotResume() {
        assertEquals(null, startupHorizonResumeFrame(emptyList(), 0, frameCount = 100))
        assertEquals(null, startupHorizonResumeFrame(emptyList(), 3, frameCount = 100))
    }

    /** A finished selection clears the list, so a position past the end is an inconsistent record. */
    @Test fun aPositionOutsideTheListDoesNotResume() {
        assertEquals(null, startupHorizonResumeFrame(listOf(0, 50, 99), 3, frameCount = 100))
        assertEquals(null, startupHorizonResumeFrame(listOf(0, 50, 99), -1, frameCount = 100))
    }

    /** config.json outlives the frames it was written for: hand edited, or re-extracted shorter. */
    @Test fun aFrameTheSequenceDoesNotHaveDoesNotResume() {
        assertEquals(null, startupHorizonResumeFrame(listOf(0, 25, 900), 2, frameCount = 100))
        assertEquals(null, startupHorizonResumeFrame(listOf(0, 25, 100), 2, frameCount = 100))
        assertEquals(null, startupHorizonResumeFrame(listOf(-1), 0, frameCount = 100))
        assertEquals(null, startupHorizonResumeFrame(listOf(0), 0, frameCount = 0))
    }

    // the suggested count (macOS `suggestedMovingHorizonCount`)

    @Test fun suggestionScalesWithSequenceLength() {
        assertEquals(12, suggestedMovingHorizonCount(1450)) // the measured good value
        assertEquals(10, suggestedMovingHorizonCount(1000))
        assertEquals(14, suggestedMovingHorizonCount(2000))
        assertEquals(22, suggestedMovingHorizonCount(5000))
    }

    @Test fun shortSequencesKeepTheOldSuggestionOfThree() {
        assertEquals(3, suggestedMovingHorizonCount(50))
        assertEquals(3, suggestedMovingHorizonCount(122))
        assertEquals(4, suggestedMovingHorizonCount(123)) // where sqrt(total/10) rounds past 3
    }

    @Test fun suggestionNeverExceedsTheSequence() {
        assertEquals(1, suggestedMovingHorizonCount(1))
        assertEquals(2, suggestedMovingHorizonCount(2))
        assertEquals(1, suggestedMovingHorizonCount(0)) // matches the stepper's floor of 1
    }

    @Test fun suggestionIsAlwaysAValidStepperValue() {
        for (total in 1..6000) {
            val n = suggestedMovingHorizonCount(total)
            assertEquals(true, n in 1..total, "suggestion $n out of 1..$total")
        }
    }

    // the remembered multiplier (macOS `preferredMovingHorizonCount` / `movingHorizonCountMultiplier`)

    @Test fun noRecordedPreferenceLeavesTheSuggestionAlone() {
        assertEquals(12, preferredMovingHorizonCount(1450, null))
        assertEquals(3, preferredMovingHorizonCount(50, null))
    }

    @Test fun aChoiceIsRecordedRelativeToWhatWasSuggested() {
        assertEquals(2.0, movingHorizonCountMultiplier(chosen = 24, total = 1450)) // suggested 12
        assertEquals(0.5, movingHorizonCountMultiplier(chosen = 6, total = 1450))
        assertEquals(1.0, movingHorizonCountMultiplier(chosen = 12, total = 1450))
    }

    /** The whole point: a choice made on one sequence carries proportionally to another length. */
    @Test fun theMultiplierCarriesToADifferentSequenceLength() {
        val m = movingHorizonCountMultiplier(chosen = 24, total = 1450) // "twice what star suggests"
        assertEquals(24, preferredMovingHorizonCount(1450, m))
        assertEquals(20, preferredMovingHorizonCount(1000, m)) // 10 suggested → 20
        assertEquals(44, preferredMovingHorizonCount(5000, m)) // 22 suggested → 44
    }

    /** Re-opening a sequence of the same length must offer exactly what was picked. */
    @Test fun recordingThenApplyingRoundTripsForEveryCount() {
        for (total in listOf(1, 2, 10, 123, 1450, 6000)) {
            for (chosen in listOf(1, 2, 3, total / 2, total).filter { it in 1..total }.distinct()) {
                val m = movingHorizonCountMultiplier(chosen, total)
                assertEquals(chosen, preferredMovingHorizonCount(total, m), "round trip $chosen of $total")
            }
        }
    }

    /** Asking for fewer must be able to go below the baseline's floor of 3. */
    @Test fun aPreferenceForFewerGoesBelowTheFloorOfThree() {
        val m = movingHorizonCountMultiplier(chosen = 1, total = 1000) // 1 of the 10 suggested
        assertEquals(1, preferredMovingHorizonCount(200, m))  // 4 suggested × 0.1 → 1, not the floor of 3
        assertEquals(2, preferredMovingHorizonCount(5000, m)) // 22 suggested × 0.1 → 2
    }

    @Test fun thePreferredCountIsAlwaysAValidStepperValue() {
        for (m in listOf(0.05, 0.5, 1.0, 2.5, 40.0)) {
            for (total in listOf(1, 2, 3, 50, 1450, 6000)) {
                val n = preferredMovingHorizonCount(total, m)
                assertEquals(true, n in 1..total, "preferred $n out of 1..$total at multiplier $m")
            }
        }
    }

    @Test fun aNonsenseMultiplierFallsBackToTheSuggestion() {
        assertEquals(12, preferredMovingHorizonCount(1450, 0.0))
        assertEquals(12, preferredMovingHorizonCount(1450, -2.0))
        assertEquals(12, preferredMovingHorizonCount(1450, Double.NaN))
        assertEquals(12, preferredMovingHorizonCount(1450, Double.POSITIVE_INFINITY))
    }

    /** A finite but preposterous multiplier must cap at the sequence, not wrap around Int range. */
    @Test fun aPreposterousMultiplierCapsAtTheSequence() {
        assertEquals(1450, preferredMovingHorizonCount(1450, 1e6))
        assertEquals(1450, preferredMovingHorizonCount(1450, Double.MAX_VALUE))
        assertEquals(1, preferredMovingHorizonCount(1, Double.MAX_VALUE))
    }
}
