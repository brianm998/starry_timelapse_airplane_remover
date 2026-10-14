package com.star.desktop.domain

import com.star.proto.DetectionType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class DetectionPreferenceTest {
    @Test fun everyTypeRoundTripsThroughItsMacOSName() {
        for (type in DetectionType.entries.filter { it != DetectionType.UNRECOGNIZED }) {
            assertEquals(type, DetectionPreference.fromPref(DetectionPreference.toPref(type)), "$type")
        }
    }

    @Test fun theNamesAreTheOnesTheMacAppWrites() {
        assertEquals("mild", DetectionPreference.toPref(DetectionType.DETECTION_MILD))
        assertEquals("strong", DetectionPreference.toPref(DetectionType.DETECTION_STRONG))
        assertEquals("stronger", DetectionPreference.toPref(DetectionType.DETECTION_STRONGER))
        assertEquals("excessive", DetectionPreference.toPref(DetectionType.DETECTION_EXCESSIVE))
        assertEquals("custom", DetectionPreference.toPref(DetectionType.DETECTION_CUSTOM))
        assertEquals("processingType", DetectionPreference.KEY)
    }

    @Test fun nothingOrSomethingUnknownIsNoPreference() {
        assertNull(DetectionPreference.fromPref(null))
        assertNull(DetectionPreference.fromPref(""))
        assertNull(DetectionPreference.fromPref("ludicrous"))
    }

    @Test fun caseAndSpacesDoNotMatter() {
        assertEquals(DetectionType.DETECTION_STRONGER, DetectionPreference.fromPref(" Stronger "))
    }
}
