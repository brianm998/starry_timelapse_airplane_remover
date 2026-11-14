package com.star.desktop.domain

import com.star.proto.AlignmentState
import kotlin.math.PI
import kotlin.math.sin

/**
 * The four example deviation charts of the "About the alignment charts" panel (macOS `AlignmentExamples`): a fixed or a moving camera, a good
 * alignment or one to watch. Fixed data, drawn by the real [com.star.desktop.ui.components.DeviationChart]; `gherkin/ui/vectors/alignmentExamples.json`
 * holds sample points both clients' generators must give.
 */
object AlignmentExamples {
    const val FRAME_COUNT = 48
    val OFFSETS = listOf(-4, -3, -2, -1, 1, 2, 3, 4)

    fun points(moving: Boolean, good: Boolean): List<DeviationPoint> {
        val out = ArrayList<DeviationPoint>()
        for (frame in 0 until FRAME_COUNT) for (offset in OFFSETS) {
            var deviation: Double
            var isGood = true
            if (moving) {
                deviation = offset * (6.0 + 3.0 * sin(2.0 * PI * frame / 48.0)) + 0.6 * sin(1.3 * frame + offset)
                if (!good) {
                    if (frame >= 20) deviation += 12.0
                    if (offset == -2 && frame in 30..35) deviation += 10.0
                    if (frame in 36..44) isGood = false
                }
            } else {
                deviation = 6.0 * offset + 0.4 * sin(1.7 * frame + 0.9 * offset)
                if (!good) {
                    if (frame == 15 || frame == 16) { deviation += 30.0; isGood = false }
                    if (offset == 3 && frame >= 30) deviation -= 8.0
                    if (frame in 38..41) isGood = false
                }
            }
            out.add(DeviationPoint(frame, offset, deviation, AlignmentState.ALIGN_HOMOGRAPHY_SUCCESS, isGood))
        }
        return out
    }
}
