package com.star.desktop.domain

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

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

    /** Q7: the playback speeds the Display picker offers are the same in both clients. */
    @Test fun thePlaybackRatesAreTheGuis() {
        assertEquals(doc.getAsJsonArray("playbackFrameRates").map { it.asInt }, PlaybackRates.choices)
    }

    /** I1: the hover text and the paragraph under each clean-method row are the gui's (the same catalogue keys), and the sheet uses them. */
    @Test fun theCleanMethodTextsAreTheGuis() {
        val texts = doc.getAsJsonObject("cleanMethod").getAsJsonObject("texts")
        val clean = texts.getAsJsonObject("cleanMethod")
        for ((name, choice) in listOf("automatic" to HighLevelClean.AUTOMATIC, "selective" to HighLevelClean.SELECTIVE)) {
            assertEquals(clean.getAsJsonObject(name)["tip"].asString, CleanMethodTexts.tipKey(choice), name)
            assertEquals(clean.getAsJsonObject(name)["description"].asString, CleanMethodTexts.descriptionKey(choice), name)
        }
        val auto = texts.getAsJsonObject("selectiveAutoClean")
        for ((name, yes) in listOf("yes" to true, "no" to false)) {
            assertEquals(auto.getAsJsonObject(name)["tip"].asString, CleanMethodTexts.autoPreservationTipKey(yes), name)
            assertEquals(auto.getAsJsonObject(name)["description"].asString, CleanMethodTexts.autoPreservationDescriptionKey(yes), name)
        }
        val dialog = listOf(File("src/main/kotlin/com/star/desktop/ui/dialogs/ProcessingSettingsDialog.kt"), File("star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/ProcessingSettingsDialog.kt"))
            .first { it.isFile }.readText()
        assertTrue("tip = { localized(CleanMethodTexts.tipKey(it)) }" in dialog)
        assertTrue("tip = { localized(CleanMethodTexts.autoPreservationTipKey(it)) }" in dialog)
        assertTrue("CleanMethodTexts.descriptionKey(HighLevelClean.AUTOMATIC)" in dialog)
        assertTrue("CleanMethodTexts.autoPreservationDescriptionKey(true)" in dialog)
    }

    /** S9: a byte count reads the same here as in the daemon's warnings (StarCore's `humanReadableBytes`). */
    @Test fun byteCountsAreFormattedAsStarCoreDoes() {
        val file = listOf(File("../gherkin/ui/vectors/byteFormat.json"), File("gherkin/ui/vectors/byteFormat.json")).first { it.isFile }
        val cases = JsonParser.parseString(file.readText()).asJsonObject.getAsJsonArray("cases")
        assertTrue(cases.size() > 10)
        for (element in cases) {
            val c = element.asJsonObject
            assertEquals(c["expected"].asString, VideoImport.formatBytes(c["bytes"].asLong), "${c["bytes"]} bytes")
        }
    }

    @Test fun theKeypointDivisorChoicesAreTheStartupPromptsAndStarCores() {
        val k = doc.getAsJsonObject("keypointDivisor")
        assertEquals(k.getAsJsonArray("presets").map { it.asDouble }, KeypointDivisor.presets.map { it.divisor })
        assertEquals(k["recommendedReduced"].asDouble, KeypointDivisor.presets[1].divisor, "the middle preset is the one the daemon recommends")
        assertEquals(k["tooHigh"].asDouble, KeypointDivisor.TOO_HIGH)
        assertEquals(k["max"].asDouble, KeypointDivisor.MAX)
    }

    private fun cleanMethodNamed(name: String): com.star.proto.CleanMethod = when (name) {
        "automatic" -> com.star.proto.CleanMethod.CLEAN_AUTOMATIC
        "autoSelective" -> com.star.proto.CleanMethod.CLEAN_AUTOMATIC_TRUE
        "selective" -> com.star.proto.CleanMethod.CLEAN_SELECTIVE
        else -> error("no clean method named $name")
    }

    /** P6: the two questions behind a clean method, as StarCore's `CleanMethod(highLevelCleanMethod:autoPreservationMode:)` puts them together. */
    @Test fun theCleanMethodChoiceIsStarCores() {
        val rule = doc.getAsJsonObject("cleanMethod")
        for (element in rule.getAsJsonArray("cases")) {
            val c = element.asJsonObject
            val high = if (c["highLevel"].asString == "selective") HighLevelClean.SELECTIVE else HighLevelClean.AUTOMATIC
            assertEquals(cleanMethodNamed(c["expected"].asString), CleanMethodChoice.method(high, c["autoPreservation"].asBoolean), c.toString())
        }
        for (element in rule.getAsJsonArray("autoPreservationStart")) {
            val c = element.asJsonObject
            assertEquals(c["expected"].asBoolean, CleanMethodChoice.autoPreservationStart(cleanMethodNamed(c["method"].asString)), c.toString())
        }
    }
}
