package com.star.desktop.domain

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Layer 0 of the parity plan (§6.2.4): the desktop's `StepRateTracker` is a hand copy of StarCore's, held to `gherkin/ui/vectors/stepRates.json`,
 * which StarCore's own is held to as well (`StepRateVectorTests`).
 */
class StepRateVectorTest {
    private val doc: JsonObject = JsonParser.parseString(
        listOf(File("../gherkin/ui/vectors/stepRates.json"), File("gherkin/ui/vectors/stepRates.json")).first { it.isFile }.readText(),
    ).asJsonObject

    private fun row(o: JsonObject) = StepRow(o["type"].asString, o["queued"].asInt, o["running"].asInt, o["done"].asInt, o["alreadyDone"].asInt)

    @Test fun theConstantsAreTheVectors() {
        assertEquals(doc["minimumOperations"].asInt, StepRateTracker.MINIMUM_OPERATIONS)
        assertEquals(doc["minimumSeconds"].asDouble, StepRateTracker.MINIMUM_SECONDS)
    }

    @Test fun everyScenarioIsWhatTheTrackerSays() {
        val scenarios = doc.getAsJsonArray("scenarios")
        assertTrue(scenarios.size() >= 10)
        for (element in scenarios) {
            val scenario = element.asJsonObject
            val name = scenario["name"].asString
            val tracker = StepRateTracker()
            for (obs in scenario.getAsJsonArray("observations")) {
                val o = obs.asJsonObject
                tracker.observe(o.getAsJsonArray("steps").map { row(it.asJsonObject) }, o["timeMs"].asLong)
            }
            val got = tracker.secondsRemaining(row(scenario.getAsJsonObject("query")))
            val expected = scenario["expected"]
            if (expected.isJsonNull) assertNull(got, name) else assertEquals(expected.asDouble, assertNotNull(got, name), 1e-9, name)
        }
    }
}
