package com.star.desktop.domain

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The frame rate as the shared preferences file holds it: Swift's coding of its `FrameRate` enum. */
class FrameRatePrefTest {
    private val gson = Gson()

    private fun parsed(json: String): Any? = gson.fromJson<Map<String, Any?>>(json, object : TypeToken<Map<String, Any?>>() {}.type)["frameRate"]

    @Test fun aStandardRateTheMacWroteIsRead() {
        assertEquals(29.97, FrameRatePref.fromPref(parsed("""{"frameRate":{"fps_29_97":{}}}""")))
        assertEquals(24.0, FrameRatePref.fromPref(parsed("""{"frameRate":{"fps_24":{}}}""")))
        assertEquals(23.976, FrameRatePref.fromPref(parsed("""{"frameRate":{"fps_23_976":{}}}""")))
    }

    @Test fun aCustomRateTheMacWroteIsRead() {
        assertEquals(12.5, FrameRatePref.fromPref(parsed("""{"frameRate":{"custom":{"_0":12.5}}}""")))
    }

    @Test fun whatIsWrittenIsWhatTheMacWouldWrite() {
        assertEquals("""{"frameRate":{"fps_29_97":{}}}""", gson.toJson(mapOf("frameRate" to FrameRatePref.toPref(29.97))))
        assertEquals("""{"frameRate":{"custom":{"_0":12.5}}}""", gson.toJson(mapOf("frameRate" to FrameRatePref.toPref(12.5))))
    }

    @Test fun everyRateRoundTrips() {
        for (rate in listOf(24.0, 25.0, 30.0, 50.0, 60.0, 23.976, 29.97, 59.94, 12.5, 1000.0, 0.5)) {
            val json = gson.toJson(mapOf("frameRate" to FrameRatePref.toPref(rate)))
            assertEquals(rate, FrameRatePref.fromPref(parsed(json)), "$rate")
        }
    }

    @Test fun anythingElseIsNoRate() {
        assertNull(FrameRatePref.fromPref(null))
        assertNull(FrameRatePref.fromPref("24"))
        assertNull(FrameRatePref.fromPref(parsed("""{"frameRate":{}}""")))
        assertNull(FrameRatePref.fromPref(parsed("""{"frameRate":{"fps_99":{}}}""")))
        assertNull(FrameRatePref.fromPref(parsed("""{"frameRate":{"custom":{"_0":-3}}}""")))
        assertNull(FrameRatePref.fromPref(parsed("""{"frameRate":{"custom":{}}}""")))
    }
}
