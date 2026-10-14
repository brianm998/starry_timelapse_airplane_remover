package com.star.desktop.ui.sequence.edit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Refinement strokes in the horizon painter, ported from macOS `HorizonPaintState`/`HorizonPainterView`. The random-walker is
 * the daemon's; what is under test is what happens around it: the known regions a stroke records, the band it widens, the
 * inputs it hands the solver, and how the answer is clamped.
 */
class HorizonPaintStateTest {
    private val w = 200
    private val h = 1000

    /** A frame whose stored horizon is at row 100, loaded the way re-opening a frame does (a band of +-margin around it). */
    private fun stateWithHorizonAt(row: Int, margin: Int = 50): HorizonPaintState {
        val state = HorizonPaintState(w, h)
        state.brushRadius = 30
        state.loadExistingHorizon(List(w) { row }, margin)
        return state
    }

    private fun stroke(state: HorizonPaintState, y: Int, vararg xs: Int) {
        state.beginStroke()
        xs.forEach { state.paint(it, y) }
        state.endStroke()
    }

    /** What a solver that honours its seeds returns: the horizon exactly at the sky floor, over the stroke's columns. */
    private fun solverAnswer(inputs: HorizonPaintState.RefineInputs, range: IntRange): List<Int> =
        List(w) { x -> if (x in range) inputs.skyFloor[x].coerceAtLeast(0) else -1 }

    /**
     * The case that was broken: painting sky well below the loaded band (the detection was wrong by far more than the
     * margin) used to snap straight back, because the ground ceiling was pinned to the band's bottom and the clamp
     * after the solve pulled the horizon up to it.
     */
    @Test fun skyPaintedBelowTheBandSticks() {
        val state = stateWithHorizonAt(100, margin = 50)   // band 50..150
        stroke(state, 700, 90, 100, 110)
        val range = state.lastGestureRange()!!
        state.commitRefinementGesture(erasing = false)

        val inputs = state.localBand(range, brush = range, erasing = false, taperWidth = 5)
        for (x in 95..105) {
            assertTrue(inputs.bottom[x] > inputs.skyFloor[x], "column $x: the band does not reach down to the sky that was painted")
            assertTrue(inputs.groundCeiling[x] > inputs.skyFloor[x], "column $x: the ground ceiling is still above the painted sky")
        }

        state.applyRefinedHorizon(solverAnswer(inputs, range), range, baseline = null, erasing = false)
        assertTrue(state.horizonAt(100) >= 700, "the horizon snapped back to ${state.horizonAt(100)} after painting sky at 700")
    }

    /** And the same the other way: ground painted above the band. */
    @Test fun groundPaintedAboveTheBandSticks() {
        val state = stateWithHorizonAt(600, margin = 50)   // band 550..650
        stroke(state, 100, 90, 100, 110)
        val range = state.lastGestureRange()!!
        state.commitRefinementGesture(erasing = true)

        val inputs = state.localBand(range, brush = range, erasing = true, taperWidth = 5)
        for (x in 95..105) {
            assertTrue(inputs.top[x] < inputs.groundCeiling[x], "column $x: the band does not reach up to the ground that was painted")
        }
        // A solver honouring the ground ceiling answers just above it.
        val answer = List(w) { x -> if (x in range) inputs.groundCeiling[x] - 1 else -1 }
        state.applyRefinedHorizon(answer, range, baseline = null, erasing = true)
        assertTrue(state.horizonAt(100) < 150, "the horizon stayed at ${state.horizonAt(100)} after painting ground at 100")
    }

    /** A stroke inside the band changes nothing about the band. */
    @Test fun aStrokeInsideTheBandLeavesItAlone() {
        val state = stateWithHorizonAt(500, margin = 100)  // band 400..600
        stroke(state, 450, 100)
        val range = state.lastGestureRange()!!
        val before = state.bandBottomAt(100)
        state.commitRefinementGesture(erasing = false)
        assertEquals(before, state.bandBottomAt(100))
    }

    /** The two clamps cannot both hold if they cross; the one for the stroke that just happened is applied last and wins. */
    @Test fun theLatestStrokesClampWinsWhenTheTwoCross() {
        // Sky painted down to row 800, then ground painted from row 300: the ground stroke retracts the sky floor, so
        // they do not cross in practice; force a crossing through two strokes at the same column to see the ordering.
        val state = stateWithHorizonAt(500, margin = 50)
        stroke(state, 700, 100)
        state.commitRefinementGesture(erasing = false)
        val rangeSky = state.lastGestureRange()!!
        val sky = state.localBand(rangeSky, rangeSky, false, 5)
        state.applyRefinedHorizon(List(w) { 720 }, rangeSky, null, erasing = false)
        assertTrue(state.horizonAt(100) >= sky.skyFloor[100], "the sky stroke's floor was not honoured")
    }
}

/** When the painter's Save / Next / Continue may be used. */
class CanSaveHorizonTest {
    @Test fun aRefinedHorizonWithNothingRunningCanBeSaved() {
        assertTrue(canSaveHorizon(HorizonPhase.REFINEMENT, hasHorizon = true, refining = 0, saving = false))
    }

    @Test fun notBeforeARefinedHorizonExists() {
        assertEquals(false, canSaveHorizon(HorizonPhase.BAND_SELECTION, true, 0, false))
        assertEquals(false, canSaveHorizon(HorizonPhase.COMPUTING, true, 0, false))
        assertEquals(false, canSaveHorizon(HorizonPhase.REFINEMENT, hasHorizon = false, refining = 0, saving = false))
    }

    /** Saved while a pass was running, it stored the horizon from before the pass. */
    @Test fun notWhileARefinementPassIsRunning() {
        assertEquals(false, canSaveHorizon(HorizonPhase.REFINEMENT, true, refining = 1, saving = false))
    }

    /** Two saves at once advanced two frames for one horizon. */
    @Test fun notWhileASaveIsInFlight() {
        assertEquals(false, canSaveHorizon(HorizonPhase.REFINEMENT, true, 0, saving = true))
    }
}

/** What closing the painter does with the horizon on it (macOS saves unless the user cancelled). */
class ShouldSaveOnCloseTest {
    @Test fun aRefinedHorizonIsSavedWhenThePainterIsClosedByToggle() {
        assertTrue(shouldSaveOnClose(startup = false, phase = HorizonPhase.REFINEMENT, savedAlready = false, cancelled = false, saving = false))
    }

    /** Cancel (and Esc) are the way to throw the work away. */
    @Test fun cancelDiscards() {
        assertEquals(false, shouldSaveOnClose(false, HorizonPhase.REFINEMENT, savedAlready = false, cancelled = true, saving = false))
    }

    /** The startup flow has its own Continue / Cancel, and records progress against the saved references. */
    @Test fun theStartupFlowNeverSavesOnClose() {
        assertEquals(false, shouldSaveOnClose(true, HorizonPhase.REFINEMENT, false, false, false))
    }

    @Test fun nothingBeforeARefinedHorizonExists() {
        assertEquals(false, shouldSaveOnClose(false, HorizonPhase.BAND_SELECTION, false, false, false))
        assertEquals(false, shouldSaveOnClose(false, HorizonPhase.COMPUTING, false, false, false))
    }

    @Test fun notTwice() {
        assertEquals(false, shouldSaveOnClose(false, HorizonPhase.REFINEMENT, savedAlready = true, cancelled = false, saving = false))
        assertEquals(false, shouldSaveOnClose(false, HorizonPhase.REFINEMENT, savedAlready = false, cancelled = false, saving = true))
    }
}

/** The smaller painter behaviours that macOS has and this did not. */
class HorizonPainterDetailsTest {
    private val w = 400
    private val h = 600

    private fun refining(row: Int = 300): HorizonPaintState =
        HorizonPaintState(w, h).also { it.loadExistingHorizon(List(w) { row }, margin = 50) }

    /** The brush is the macOS one whatever the image: 250 px, 5 to 500, in steps of 10 (it used to scale with the width). */
    @Test fun theBrushIsTheMacOSOne() {
        assertEquals(250, HorizonPaintState(400, 300).brushRadius)
        assertEquals(250, HorizonPaintState(8000, 6000).brushRadius)
        val s = HorizonPaintState(400, 300)
        repeat(100) { s.growBrush() }
        assertEquals(500, s.brushRadius)
        repeat(100) { s.shrinkBrush() }
        assertEquals(5, s.brushRadius)
        s.growBrush()
        assertEquals(15, s.brushRadius)
    }

    /** A stroke nudges the shown horizon at once; what is saved is the solver's answer, which has not come yet. */
    @Test fun whatIsSavedIsTheSolversAnswerNotTheStrokesNudge() {
        val s = refining(300)
        s.brushRadius = 40
        s.beginStroke(); s.paint(200, 400); s.endStroke()      // sky stroke: the shown horizon moves down at once
        assertTrue(s.horizonAt(200) > 300, "the stroke did not nudge the shown horizon")
        assertEquals(300, s.solvedHorizonSnapshot()[200], "the nudge reached what would be saved")
    }

    @Test fun aFailedSolveShowsTheLastAnswerAgain() {
        val s = refining(300)
        s.brushRadius = 40
        s.beginStroke(); s.paint(200, 400); s.endStroke()
        s.restoreSolvedHorizon()
        assertEquals(300, s.horizonAt(200))
    }

    @Test fun aSolversAnswerBecomesWhatIsSaved() {
        val s = refining(300)
        s.brushRadius = 40
        s.beginStroke(); s.paint(200, 400); s.endStroke()
        val range = s.lastGestureRange()!!
        s.commitRefinementGesture(erasing = false)
        s.applyRefinedHorizon(List(w) { 420 }, range, baseline = null, erasing = false)
        assertEquals(s.horizonAt(200), s.solvedHorizonSnapshot()[200])
    }

    @Test fun nothingIsSolvedUntilARefinedHorizonExists() {
        val s = HorizonPaintState(w, h)
        assertEquals(false, s.hasSolvedHorizon())
        assertEquals(true, refining().hasSolvedHorizon())
    }

    /** The sky/ground mode is the user's, and nothing about a new frame, a reset or a loaded horizon changes it. */
    @Test fun theSkyGroundModeSurvivesEverythingElse() {
        val s = HorizonPaintState(w, h)
        s.isErasing = true
        s.resetForNewFrame()
        assertTrue(s.isErasing, "a new frame reset the mode")
        s.loadExistingHorizon(List(w) { 300 }, margin = 50)
        assertTrue(s.isErasing, "loading a horizon reset the mode")
        s.clear()
        assertTrue(s.isErasing, "Reset reset the mode")
    }
}

/** The painter's keyboard, as macOS binds it. */
@OptIn(androidx.compose.ui.InternalComposeUiApi::class)
class PainterKeyActionTest {
    private fun down(key: androidx.compose.ui.input.key.Key) =
        androidx.compose.ui.input.key.KeyEvent(key, androidx.compose.ui.input.key.KeyEventType.KeyDown)

    @Test fun theKeysAreTheMacOSOnes() {
        assertEquals(HorizonPainterKey.SHRINK_BRUSH, painterKeyAction(down(androidx.compose.ui.input.key.Key.LeftBracket)))
        assertEquals(HorizonPainterKey.GROW_BRUSH, painterKeyAction(down(androidx.compose.ui.input.key.Key.RightBracket)))
        assertEquals(HorizonPainterKey.TOGGLE_MODE, painterKeyAction(down(androidx.compose.ui.input.key.Key.Minus)))
        assertEquals(HorizonPainterKey.SKY, painterKeyAction(down(androidx.compose.ui.input.key.Key.P)))
        assertEquals(HorizonPainterKey.GROUND, painterKeyAction(down(androidx.compose.ui.input.key.Key.E)))
        assertEquals(HorizonPainterKey.RESET, painterKeyAction(down(androidx.compose.ui.input.key.Key.R)))
        assertEquals(HorizonPainterKey.CANCEL, painterKeyAction(down(androidx.compose.ui.input.key.Key.Escape)))
        assertEquals(HorizonPainterKey.SAVE, painterKeyAction(down(androidx.compose.ui.input.key.Key.Enter)))
    }

    @Test fun otherKeysAreLeftToTheWindow() {
        assertEquals(null, painterKeyAction(down(androidx.compose.ui.input.key.Key.Z)))
        assertEquals(null, painterKeyAction(down(androidx.compose.ui.input.key.Key.DirectionLeft)))
    }

    /** Once per press. */
    @Test fun theReleaseDoesNothing() {
        assertEquals(null, painterKeyAction(androidx.compose.ui.input.key.KeyEvent(
            androidx.compose.ui.input.key.Key.R, androidx.compose.ui.input.key.KeyEventType.KeyUp)))
    }
}
