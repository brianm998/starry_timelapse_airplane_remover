package com.star.desktop.domain

import com.star.proto.CleanMethod
import com.star.proto.Config
import com.star.proto.DetectionType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The three GPU toggles as a machine-wide choice: what a freshly opened session is changed to, and what a settings change is remembered as. */
class GpuToggleTest {

    private fun session(merge: Boolean? = true, sift: Boolean? = true, akaze: Boolean? = true): Config =
        Config.newBuilder()
            .setCleanMethod(CleanMethod.CLEAN_SELECTIVE)
            .setDetectionType(DetectionType.DETECTION_STRONGER)
            .setHorizonDetectionEnabled(true)
            .setTripodHeadWasMoving(true)
            .also { b ->
                merge?.let { b.setUseGpuAcceleration(it) }
                sift?.let { b.setUseGpuForSift(it) }
                akaze?.let { b.setUseGpuForAkaze(it) }
            }
            .build()

    private fun choices(vararg chosen: Pair<GpuToggle, Boolean>): (GpuToggle) -> Boolean? = chosen.toMap()::get

    @Test fun nothingChosenLeavesTheSessionAlone() {
        assertNull(GpuToggle.changesToMatch(choices(), session()))
        assertNull(GpuToggle.changesToMatch(choices(), session(merge = false, sift = false, akaze = false)))
    }

    @Test fun aChoiceTheSessionAlreadyHasIsNotSentAgain() {
        assertNull(GpuToggle.changesToMatch(choices(GpuToggle.MERGE to true, GpuToggle.SIFT to false), session(merge = true, sift = false)))
    }

    @Test fun aToggleTurnedOffOnThisMachineIsTurnedOffOnTheSequenceJustOpened() {
        val changes = assertNotNull(GpuToggle.changesToMatch(choices(GpuToggle.SIFT to false, GpuToggle.AKAZE to false), session()))
        assertTrue(changes.hasUseGpuForSift() && !changes.useGpuForSift)
        assertTrue(changes.hasUseGpuForAkaze() && !changes.useGpuForAkaze)
        // the one the user did not touch is not in it: sending it would mark it as chosen
        assertFalse(changes.hasUseGpuAcceleration())
    }

    /** A sequence last saved with a toggle off does not keep a machine that has since chosen it on from using it. */
    @Test fun aChoiceToTurnOneOnWinsOverASequenceSavedWithItOff() {
        val changes = assertNotNull(GpuToggle.changesToMatch(choices(GpuToggle.MERGE to true), session(merge = false)))
        assertTrue(changes.hasUseGpuAcceleration() && changes.useGpuAcceleration)
    }

    /** `Sequence.UpdateConfig` reads these four every time, so a config without them would put them back to the proto's zeros. */
    @Test fun theSettingsEveryUpdateReadsGoBackAsTheyStand() {
        val changes = assertNotNull(GpuToggle.changesToMatch(choices(GpuToggle.MERGE to false), session()))
        assertEquals(CleanMethod.CLEAN_SELECTIVE, changes.cleanMethod)
        assertEquals(DetectionType.DETECTION_STRONGER, changes.detectionType)
        assertTrue(changes.horizonDetectionEnabled)
        assertTrue(changes.tripodHeadWasMoving)
    }

    /** A daemon that predates a toggle does not send it, and has nothing to apply a choice to. */
    @Test fun aToggleTheDaemonDoesNotHaveIsSkipped() {
        assertNull(GpuToggle.changesToMatch(choices(GpuToggle.SIFT to false), session(sift = null)))
        val changes = assertNotNull(GpuToggle.changesToMatch(choices(GpuToggle.SIFT to false, GpuToggle.AKAZE to false), session(sift = null)))
        assertFalse(changes.hasUseGpuForSift())
        assertTrue(changes.hasUseGpuForAkaze())
    }

    @Test fun whatTheUserChangedIsWhatIsRemembered() {
        val changed = GpuToggle.changed(session(), session(merge = false, akaze = false))
        assertEquals(mapOf(GpuToggle.MERGE to false, GpuToggle.AKAZE to false), changed)
        assertEquals(mapOf(GpuToggle.SIFT to true), GpuToggle.changed(session(sift = false), session(sift = true)))
    }

    /** Saving the sheet over a daemon that sends the same values, or none, remembers nothing: the choice is the user's, not whatever the sheet held. */
    @Test fun anUnchangedOrAbsentToggleIsNotRemembered() {
        assertEquals(emptyMap(), GpuToggle.changed(session(), session()))
        assertEquals(emptyMap(), GpuToggle.changed(session(sift = null), session(sift = null)))
        assertEquals(emptyMap(), GpuToggle.changed(session(sift = null), session(sift = false)))
    }

    /** These are Swift's property names, which are the other client's wire format for the same file. */
    @Test fun theKeysAreTheOnesTheMacAppWrites() {
        assertEquals(listOf("useGPUForMerge", "useGPUForSIFT", "useGPUForAKAZE"), GpuToggle.entries.map { it.key })
    }
}
