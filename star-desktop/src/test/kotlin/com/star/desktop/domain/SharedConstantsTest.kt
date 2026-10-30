package com.star.desktop.domain

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Layer 0 of the parity plan (§6.2.4): `WorkingLocation` and `KeypointDivisor` hold numbers StarCore owns, copied by hand.
 * `gherkin/ui/vectors/constants.json` has them; the gui's `SharedConstantsTests` checks the file against StarCore, this checks the copies.
 */
class SharedConstantsTest {
    private val doc: JsonObject = JsonParser.parseString(
        listOf(File("../gherkin/ui/vectors/constants.json"), File("gherkin/ui/vectors/constants.json")).first { it.isFile }.readText(),
    ).asJsonObject

    @Test fun theDiskSpaceRatioIsStarCores() {
        val disk = doc.getAsJsonObject("diskSpace")
        assertEquals(disk["peakToInputRatio"].asDouble, WorkingLocation.PEAK_TO_INPUT_RATIO)
        for (element in disk.getAsJsonArray("runBytes")) {
            val c = element.asJsonObject
            assertEquals(c["expected"].asLong, WorkingLocation.runBytes(c["inputBytes"].asLong), "${c["inputBytes"]} bytes in")
        }
    }

    @Test fun theKeypointDivisorChoicesAreTheStartupPromptsAndStarCores() {
        val k = doc.getAsJsonObject("keypointDivisor")
        assertEquals(k.getAsJsonArray("presets").map { it.asDouble }, KeypointDivisor.presets.map { it.divisor })
        assertEquals(k["recommendedReduced"].asDouble, KeypointDivisor.presets[1].divisor, "the middle preset is the one the daemon recommends")
        assertEquals(k["tooHigh"].asDouble, KeypointDivisor.TOO_HIGH)
        assertEquals(k["max"].asDouble, KeypointDivisor.MAX)
    }
}
