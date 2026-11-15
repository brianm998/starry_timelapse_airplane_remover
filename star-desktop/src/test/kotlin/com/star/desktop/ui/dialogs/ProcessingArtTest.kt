package com.star.desktop.ui.dialogs

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.runComposeUiTest
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The Processing heading's robot: the gear turns once every 4 s while the window is up (A2). */
@OptIn(ExperimentalTestApi::class)
class ProcessingArtTest {
    @Test
    fun processingArtTurnsWhileOpen() = runComposeUiTest {
        var angle: () -> Float = { -1f }
        mainClock.autoAdvance = false
        setContent {
            val a = rememberGearAngle()
            angle = a
            ProcessingRobot(a)
        }
        mainClock.advanceTimeByFrame()
        mainClock.advanceTimeByFrame()
        val start = angle()
        mainClock.advanceTimeBy(1000, ignoreFrameDuration = true)
        mainClock.advanceTimeByFrame()
        val oneSecond = angle()
        mainClock.advanceTimeBy(1000, ignoreFrameDuration = true)
        mainClock.advanceTimeByFrame()
        val twoSeconds = angle()
        assertTrue(start < 20f, "starts near 0, was $start")
        assertEquals(90f, oneSecond, 20f)
        assertEquals(180f, twoSeconds, 20f)
    }

    @Test
    fun gearAngleIsOneLinearTurnPerFourSeconds() {
        assertEquals(0f, ProcessingRobotGeometry.gearAngle(0))
        assertEquals(90f, ProcessingRobotGeometry.gearAngle(1000))
        assertEquals(180f, ProcessingRobotGeometry.gearAngle(2000))
        assertEquals(0f, ProcessingRobotGeometry.gearAngle(4000))
        assertEquals(45f, ProcessingRobotGeometry.gearAngle(4500))
    }

    @Test
    fun geometryMatchesTheGuiAndSpinnerIsGone() {
        assertEquals(56, ProcessingRobotGeometry.BOX)
        val src = File("src/main/kotlin/com/star/desktop/ui/dialogs/ProcessingModal.kt").readText()
        assertTrue(src.contains("testTag(\"processing.modal\")"))
        assertFalse(src.contains("CircularProgressIndicator("))
        val gui = File("../gui/star/ProcessingModalView.swift")
        if (gui.exists()) {
            val swift = gui.readText()
            assertTrue(swift.contains("static let hubX: CGFloat = ${ProcessingRobotGeometry.HUB_X}"))
            assertTrue(swift.contains("static let hubY: CGFloat = ${ProcessingRobotGeometry.HUB_Y}"))
            assertTrue(swift.contains("static let gearSize: CGFloat = ${ProcessingRobotGeometry.GEAR_SIZE}"))
        }
    }
}
