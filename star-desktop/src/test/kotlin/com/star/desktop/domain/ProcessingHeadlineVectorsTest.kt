package com.star.desktop.domain

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.star.desktop.i18n.Strings
import com.star.proto.FrameExtraction
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Layer 0 of the parity plan (§6.2.4): `ProcessingHeadline.kt` is a copy of StarCore's `ProcessingHeadline`, which had drifted once.
 * `gherkin/ui/vectors/processingHeadline.json` holds inputs and what StarCore says for them (the gui's test records and checks it); this
 * checks the copy says the same.
 */
class ProcessingHeadlineVectorsTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private val doc: JsonObject = JsonParser.parseString(
        listOf(File("../gherkin/ui/vectors/processingHeadline.json"), File("gherkin/ui/vectors/processingHeadline.json")).first { it.isFile }.readText(),
    ).asJsonObject

    private fun rows(array: com.google.gson.JsonArray): List<StepRow> = array.map { it.asJsonObject }.map {
        StepRow(it["type"].asString, it["queued"].asInt, it["running"].asInt, it["done"].asInt, it["alreadyDone"].asInt)
    }

    private fun expected(case: JsonObject): String? = case["expected"].takeIf { !it.isJsonNull }?.asString

    @Test fun theHeadlinesAreStarCores() {
        val cases = doc.getAsJsonArray("headline")
        assertEquals(true, cases.size() > 5, "no vectors")
        for (element in cases) {
            val c = element.asJsonObject
            val extraction = c["extraction"].takeIf { !it.isJsonNull }?.asJsonObject?.let {
                FrameExtraction.newBuilder().setActive(true).setComplete(false)
                    .setEtaKnown(it["etaKnown"].asBoolean).setEtaSeconds(it["etaSeconds"].asDouble).setError(it["error"].asString).build()
            }
            val got = ProcessingHeadline.text(rows(c.getAsJsonArray("steps")), extraction, c["hasPlan"].asBoolean, c["framesComplete"].asInt, c["frameCount"].asInt)
            assertEquals(expected(c), got, c["name"].asString)
        }
    }

    @Test fun theDurationsAreStarCores() {
        for (element in doc.getAsJsonArray("duration")) {
            val c = element.asJsonObject
            assertEquals(expected(c), ProcessingHeadline.duration(c["seconds"].asDouble), "${c["seconds"]} seconds")
        }
    }

    @Test fun theOverallEstimatesAreStarCores() {
        for (element in doc.getAsJsonArray("overall")) {
            val c = element.asJsonObject
            val remaining = c.getAsJsonObject("secondsRemaining").entrySet().associate { it.key to it.value.asDouble }
            val got = ProcessingHeadline.overallText(rows(c.getAsJsonArray("steps"))) { remaining[it.type] }
            assertEquals(expected(c), got, c["name"].asString)
        }
    }
}
