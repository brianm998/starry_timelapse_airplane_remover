package com.star.desktop.domain

import com.google.gson.JsonParser
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The example charts' data is `gherkin/ui/vectors/alignmentExamples.json` (the gui's `testAlignmentExamplesMatchVectors` checks the same file). */
class AlignmentExamplesTest {
    private fun read(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()

    @Test fun matchesVectors() {
        val doc = JsonParser.parseString(read("gherkin/ui/vectors/alignmentExamples.json")).asJsonObject
        assertEquals(AlignmentExamples.FRAME_COUNT, doc["frameCount"].asInt)
        assertEquals(doc.getAsJsonArray("offsets").map { it.asInt }, AlignmentExamples.OFFSETS)
        val cases = mapOf("fixedGood" to (false to true), "fixedBad" to (false to false), "movingGood" to (true to true), "movingBad" to (true to false))
        for ((name, kind) in cases) {
            val points = AlignmentExamples.points(kind.first, kind.second)
            assertEquals(48 * 8, points.size, name)
            assertTrue(points.all { it.state == com.star.proto.AlignmentState.ALIGN_HOMOGRAPHY_SUCCESS }, name)
            val samples = doc.getAsJsonArray(name)
            assertTrue(samples.size() >= 12, "$name lost samples")
            for (s in samples.map { it.asJsonObject }) {
                val p = points.first { it.frame == s["frame"].asInt && it.offset == s["offset"].asInt }
                assertEquals(s["deviation"].asDouble, p.deviation, 0.0006, "$name ${p.frame} ${p.offset}")
                assertEquals(s["good"].asBoolean, p.isGood, "$name ${p.frame} ${p.offset}")
            }
        }
    }
}
