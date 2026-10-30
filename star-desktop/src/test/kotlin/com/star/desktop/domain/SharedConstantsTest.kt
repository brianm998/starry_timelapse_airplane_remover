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

    /** P14: the render sheet's custom frame rate field takes 0.01 to 1000 in both clients. */
    @Test fun theCustomFrameRateRuleIsTheGuis() {
        val rule = doc.getAsJsonObject("customFrameRate")
        assertEquals(rule["min"].asDouble, RenderVideo.CUSTOM_MIN)
        assertEquals(rule["max"].asDouble, RenderVideo.CUSTOM_MAX)
        for (element in rule.getAsJsonArray("cases")) {
            val c = element.asJsonObject
            val expected = c["expected"].takeIf { !it.isJsonNull }?.asDouble
            assertEquals(expected, RenderVideo.customRate(c["text"].asString), "\"${c["text"].asString}\"")
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
