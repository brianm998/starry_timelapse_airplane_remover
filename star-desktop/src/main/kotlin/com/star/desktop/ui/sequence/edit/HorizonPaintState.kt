package com.star.desktop.ui.sequence.edit

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlin.math.ceil
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** The three steps of the horizon painter, matching macOS `HorizonPainterPhase`. */
enum class HorizonPhase { BAND_SELECTION, COMPUTING, REFINEMENT }

/**
 * State for one horizon-painting session, a port of macOS `HorizonPaintState`. Works entirely in
 * **image space** (one slot per image column): the Kotlin painter composites in screen space, so
 * sending `viewWidth = imageWidth` to the daemon keeps the detector's view↔image scale at 1.
 *
 * Workflow: the user paints a **band** that brackets the horizon ([HorizonPhase.BAND_SELECTION]);
 * once it spans the full width the view runs the combined detector ([HorizonPhase.COMPUTING]); then
 * the user refines the detected sky with sky/ground brushes ([HorizonPhase.REFINEMENT]), each stroke
 * re-running the random-walker over the affected columns.
 *
 * A [version] counter bumps on every mutation so the Canvas (draw-phase read) and toolbar
 * (composition read) refresh without observing the underlying `IntArray`s element-by-element.
 *
 * The instance is reused across startup frame advances ([resetForNewFrame]) so [brushRadius] and
 * [isErasing] survive them (matching macOS `resetForNewFrame`), but the mode is Sky on every other way in: the painter opens on
 * Sky, and Reset and band selection put it back (the band is always additive, and its toolbar has no sky/ground buttons to
 * undo a Ground left over from before).
 */
class HorizonPaintState(val imageWidth: Int, val imageHeight: Int) {

    var version by mutableStateOf(0)
        private set
    private fun bump() { version++ }

    // Bumps whenever the painted data is invalidated (clear / new-frame reset). An in-flight daemon
    // compute captures this at launch and discards its result if it changed (macOS expansionGeneration).
    private var gen = 0
    fun generation(): Int = gen

    private var currentPhase by mutableStateOf(HorizonPhase.BAND_SELECTION)

    /**
     * Current workflow step. Assigning it triggers recomposition + redraw (it is read in the Canvas). Going to band selection puts the brush
     * back on Sky, as the gui does: there is no sky/ground choice there to correct it, and a frame banded from scratch is not the one the
     * Ground mode was chosen on.
     */
    var phase: HorizonPhase
        get() = currentPhase
        set(value) {
            currentPhase = value
            if (value == HorizonPhase.BAND_SELECTION) isErasing = false
        }

    // ---- brush (image px; the same sizes as macOS, whatever the image's size) ----
    val minBrush: Int get() = MIN_BRUSH
    val maxBrush: Int get() = MAX_BRUSH
    var brushRadius by mutableStateOf(DEFAULT_BRUSH)
    fun growBrush() { brushRadius = (brushRadius + BRUSH_STEP).coerceAtMost(maxBrush) }
    fun shrinkBrush() { brushRadius = (brushRadius - BRUSH_STEP).coerceAtLeast(minBrush) }

    /**
     * Refinement only: false = paint sky (adds), true = paint ground (removes). Starts on Sky and returns to it with band selection, so
     * it outlives a new frame only when that frame has a horizon to refine ([resetForNewFrame]); nothing keeps it for the next time the
     * painter opens.
     */
    var isErasing by mutableStateOf(false)

    // ---- per-column data (image space; -1 = unset) ----
    private val bandTop = IntArray(imageWidth) { -1 }            // top of the painted band
    private val bandBottom = IntArray(imageWidth) { -1 }         // bottom of the painted band
    private val knownSkyFloor = IntArray(imageWidth) { -1 }      // lowest row known to be sky
    private val knownGroundCeiling = IntArray(imageWidth) { -1 } // highest row known to be ground
    private val horizonY = IntArray(imageWidth) { -1 }           // detected/refined horizon, as shown (a stroke nudges it before the solver answers)
    private val solvedHorizon = IntArray(imageWidth) { -1 }      // the solver's last answer: what gets saved (macOS lastHorizonY)

    // ---- gesture tracking ----
    private var lastX: Int? = null
    private var lastY: Int? = null
    private var newSegment = true
    private val gestureColTop = IntArray(imageWidth) { Int.MAX_VALUE }
    private val gestureColBottom = IntArray(imageWidth) { Int.MIN_VALUE }
    private var gMinX = Int.MAX_VALUE
    private var gMaxX = Int.MIN_VALUE
    // Snapshot of horizonY at the start of a refinement stroke, so columns the random-walker leaves
    // unresolved can revert to the smooth pre-stroke value instead of keeping the jagged optimistic one.
    private var preStrokeHorizon: IntArray? = null

    private fun resetGesture() {
        for (i in 0 until imageWidth) { gestureColTop[i] = Int.MAX_VALUE; gestureColBottom[i] = Int.MIN_VALUE }
        gMinX = Int.MAX_VALUE
        gMaxX = Int.MIN_VALUE
    }

    // ---- read accessors (draw layer) ----
    fun bandTopAt(x: Int): Int = if (x in 0 until imageWidth) bandTop[x] else -1
    fun bandBottomAt(x: Int): Int = if (x in 0 until imageWidth) bandBottom[x] else -1
    fun horizonAt(x: Int): Int = if (x in 0 until imageWidth) horizonY[x] else -1
    fun hasBand(): Boolean = bandTop.any { it >= 0 }
    fun hasHorizon(): Boolean = horizonY.any { it >= 0 }

    /** Fraction of columns covered by the painted band (0..1) — drives the "N%" coverage label. */
    val bandCoverage: Double get() = bandTop.count { it >= 0 }.toDouble() / max(1, imageWidth)

    /** True when the band spans the full width (within an edge margin) with no interior gaps. */
    val isBandComplete: Boolean
        get() {
            val edge = max(10, imageWidth / 50)
            var first = -1
            var last = -1
            for (x in 0 until imageWidth) if (bandTop[x] >= 0) { if (first < 0) first = x; last = x }
            if (first < 0) return false
            if (!(first <= edge && last >= imageWidth - 1 - edge)) return false
            for (x in first..last) if (bandTop[x] < 0) return false
            return true
        }

    // ---- snapshots (to send to the daemon / save) ----
    fun bandTopSnapshot(): List<Int> = bandTop.toList()
    fun bandBottomSnapshot(): List<Int> = bandBottom.toList()
    fun horizonSnapshot(): List<Int> = horizonY.toList()

    /**
     * The horizon the solver last produced, which is what to save: [horizonSnapshot] is what is *shown*, and between a
     * stroke and the solver's answer that is the stroke's optimistic nudge (and stays so if the solver fails). macOS
     * saves `lastHorizonY` for the same reason.
     */
    fun solvedHorizonSnapshot(): List<Int> = solvedHorizon.toList()
    fun hasSolvedHorizon(): Boolean = solvedHorizon.any { it >= 0 }

    /** Show the solver's last answer again, undoing a stroke's optimistic nudge (the solve for it failed). */
    fun restoreSolvedHorizon() {
        for (i in 0 until imageWidth) horizonY[i] = solvedHorizon[i]
        bump()
    }
    /** The pre-stroke horizon baseline captured at the start of the current refinement stroke. */
    fun preStrokeBaseline(): IntArray? = preStrokeHorizon

    /** Whether any paint has gone on since the last [clear]: what the frame-change confirmation asks about (macOS `hasStrokes`). */
    var hasStrokes by mutableStateOf(false)
        private set

    // ---- painting ----
    fun beginStroke() { newSegment = true }
    fun endStroke() { lastX = null; lastY = null; newSegment = true }

    /** Paint a brush stamp at image (x, y), gap-filling from the previous sample in the same stroke. */
    fun paint(x: Int, y: Int) {
        if (phase == HorizonPhase.COMPUTING) return
        hasStrokes = true
        if (newSegment) {
            resetGesture()
            if (phase == HorizonPhase.REFINEMENT) preStrokeHorizon = horizonY.copyOf()
        }
        val cy = y.coerceIn(0, imageHeight - 1)
        val lx = lastX
        val ly = lastY
        if (!newSegment && lx != null && ly != null) {
            val dist = hypot((x - lx).toDouble(), (cy - ly).toDouble())
            val step = max(brushRadius * 0.5, 1.0)
            if (dist > step) {
                val steps = ceil(dist / step).toInt()
                for (i in 1 until steps) {
                    val t = i.toDouble() / steps
                    stamp((lx + t * (x - lx)).roundToInt(), (ly + t * (cy - ly)).roundToInt())
                }
            }
        }
        newSegment = false
        stamp(x, cy)
        lastX = x
        lastY = cy
        bump()
    }

    private fun stamp(cx: Int, cy: Int) {
        val r = brushRadius
        val r2 = r.toLong() * r
        val colLo = max(0, cx - r)
        val colHi = min(imageWidth - 1, cx + r)
        for (col in colLo..colHi) {
            val dx = (col - cx).toLong()
            val dy2 = r2 - dx * dx
            if (dy2 < 0) continue
            val dy = sqrt(dy2.toDouble()).toInt()
            val top = (cy - dy).coerceIn(0, imageHeight - 1)
            val bot = (cy + dy).coerceIn(0, imageHeight - 1)
            gestureColTop[col] = min(gestureColTop[col], top)
            gestureColBottom[col] = max(gestureColBottom[col], bot)
            if (col < gMinX) gMinX = col
            if (col > gMaxX) gMaxX = col
            if (phase == HorizonPhase.BAND_SELECTION) {
                bandTop[col] = if (bandTop[col] < 0) top else min(bandTop[col], top)
                bandBottom[col] = if (bandBottom[col] < 0) bot else max(bandBottom[col], bot)
            } else if (horizonY[col] >= 0) {
                // REFINEMENT optimistic feedback — only nudge columns that already have a horizon, so a
                // brush never fabricates a horizon (or, for the ground brush, momentarily adds sky) in a
                // column the detector left unset. The random-walker refines on stroke end.
                if (isErasing) {
                    if (top < horizonY[col]) horizonY[col] = top          // ground: push horizon up
                } else {
                    if (bot > horizonY[col]) horizonY[col] = bot          // sky: push horizon down
                }
            }
        }
    }

    /** The horizontal span touched by the just-finished stroke, or null if it touched nothing. */
    fun lastGestureRange(): IntRange? = if (gMaxX >= gMinX && gMaxX >= 0) gMinX..gMaxX else null

    /**
     * Commit a refinement stroke into the known-region map (macOS `commitRefinementGesture`): a sky
     * stroke pushes [knownSkyFloor] down; a ground stroke pushes [knownGroundCeiling] up. Each retracts
     * the opposite region where they now overlap so a stroke can undo a prior opposite stroke.
     *
     * The stroke also widens the band under the brush. The band is a search region, not a verdict, so a
     * stroke that reaches outside it pushes it open rather than being clipped by it: without that the
     * painter could not repair a horizon that was wrong by more than the band's margin (the ground ceiling
     * is pinned to the band's bottom, and the clamp after the solve pulled painted sky straight back to it).
     */
    fun commitRefinementGesture(erasing: Boolean) {
        val lastRow = imageHeight - 1
        for (col in 0 until imageWidth) {
            if (gestureColBottom[col] == Int.MIN_VALUE) continue
            val brushTop = gestureColTop[col]
            val brushBottom = gestureColBottom[col]
            if (erasing) {
                // Open the band above the brush first, so the retraction below is not clipped back to the old search region.
                if (bandTop[col] >= 0) bandTop[col] = min(bandTop[col], (brushTop - 1).coerceIn(0, lastRow))
                knownGroundCeiling[col] = if (knownGroundCeiling[col] < 0) brushTop else min(knownGroundCeiling[col], brushTop)
                // Retract the sky floor if it reaches down into the rows just marked as ground (sf >= brushTop),
                // so erasing fully undoes a prior sky stroke.
                val sf = knownSkyFloor[col]
                if (sf >= brushTop) {
                    knownSkyFloor[col] = max(brushTop - 1, bandTop[col].coerceAtLeast(0))
                }
            } else {
                // Open the band below the brush first, for the same reason.
                if (bandBottom[col] >= 0) bandBottom[col] = max(bandBottom[col], (brushBottom + 1).coerceIn(0, lastRow))
                knownSkyFloor[col] = if (knownSkyFloor[col] < 0) brushBottom else max(knownSkyFloor[col], brushBottom)
                // Retract the ground ceiling if it reaches up into the rows just marked as sky (gc <= brushBottom),
                // so painting fully undoes a prior erase.
                val gc = knownGroundCeiling[col]
                if (gc in 0..brushBottom) {
                    val ceiling = if (bandBottom[col] >= 0) bandBottom[col] else imageHeight
                    knownGroundCeiling[col] = min(brushBottom + 1, ceiling)
                }
            }
        }
    }

    /**
     * Build the random-walker inputs for [expanded], with -1 outside so the solver stays local, then
     * taper the moved locked boundary (sky floor for paint, ground ceiling for erase) into the margin
     * at the [brush] X-edges — macOS `taperLockedBoundary` (HorizonPainterView.swift:402-443), which
     * removes a small downward dip at the brush edges from the random-walker's step-edge diffusion.
     */
    fun localBand(expanded: IntRange, brush: IntRange, erasing: Boolean, taperWidth: Int): RefineInputs {
        val top = IntArray(imageWidth) { -1 }
        val bottom = IntArray(imageWidth) { -1 }
        val sky = IntArray(imageWidth) { -1 }
        val ground = IntArray(imageWidth) { -1 }
        for (col in expanded) {
            if (col !in 0 until imageWidth) continue
            top[col] = bandTop[col]
            bottom[col] = bandBottom[col]
            sky[col] = knownSkyFloor[col]
            ground[col] = knownGroundCeiling[col]
        }
        val brushLeft = max(expanded.first, brush.first)
        val brushRight = min(expanded.last, brush.last)
        if (brushLeft <= brushRight) {
            if (erasing) taperBoundary(ground, brushLeft, brushRight, expanded.first, expanded.last, taperWidth, pushUp = true)
            else taperBoundary(sky, brushLeft, brushRight, expanded.first, expanded.last, taperWidth, pushUp = false)
        }
        // Keep the band consistent with the seeds it has to contain. The commit widened the stored band under the
        // brush, but the taper above pushes the locked boundary out into the margin columns as well, and the solver
        // treats a column whose sky floor sits at or below its band bottom (or ground ceiling at or above its band
        // top) as having no gap left to solve.
        for (col in expanded) {
            if (col !in 0 until imageWidth) continue
            if (sky[col] >= 0 && bottom[col] >= 0 && sky[col] >= bottom[col]) bottom[col] = min(imageHeight - 1, sky[col] + 1)
            if (ground[col] >= 0 && top[col] >= 0 && ground[col] <= top[col]) top[col] = max(0, ground[col] - 1)
        }
        return RefineInputs(top.toList(), bottom.toList(), sky.toList(), ground.toList())
    }

    private fun taperBoundary(arr: IntArray, brushLeft: Int, brushRight: Int, outerLeft: Int, outerRight: Int, taperWidth: Int, pushUp: Boolean) {
        fun combine(prior: Int, tapered: Int) = if (pushUp) min(prior, tapered) else max(prior, tapered)
        val edgeL = arr[brushLeft]
        if (edgeL >= 0) {
            val extendStart = max(outerLeft, brushLeft - taperWidth)
            val span = brushLeft - extendStart
            if (span > 0) for (col in extendStart until brushLeft) {
                val prior = arr[col]
                if (prior < 0) continue
                val t = (col - extendStart).toDouble() / span
                arr[col] = combine(prior, ((1 - t) * prior + t * edgeL).toInt())
            }
        }
        val edgeR = arr[brushRight]
        if (edgeR >= 0) {
            val extendEnd = min(outerRight, brushRight + taperWidth)
            val span = extendEnd - brushRight
            if (span > 0) for (col in (brushRight + 1)..extendEnd) {
                val prior = arr[col]
                if (prior < 0) continue
                val t = (extendEnd - col).toDouble() / span
                arr[col] = combine(prior, ((1 - t) * prior + t * edgeR).toInt())
            }
        }
    }

    data class RefineInputs(
        val top: List<Int>,
        val bottom: List<Int>,
        val skyFloor: List<Int>,
        val groundCeiling: List<Int>,
    )

    /**
     * Merge a random-walker result into the refined horizon for [range], then clamp every column so
     * explicit sky/ground strokes are never overridden (macOS merge + clamp in `triggerObjectSelection`).
     * Columns the solver left unresolved (-1) fall back to [baseline] (the pre-stroke horizon) rather
     * than keeping the jagged optimistic brush value.
     *
     * The sky floor and the ground ceiling cannot both be honoured if they ever cross, so the clamp for the
     * stroke that just happened ([erasing]: ground, else sky) is applied last and wins: the user's latest
     * instruction is the one that must never be silently discarded.
     */
    fun applyRefinedHorizon(result: List<Int>, range: IntRange, baseline: IntArray?, erasing: Boolean) {
        for (col in range) {
            if (col !in 0 until imageWidth) continue
            val r = if (col < result.size) result[col] else -1
            horizonY[col] = when {
                r >= 0 -> r
                baseline != null -> baseline[col]
                else -> horizonY[col]
            }
        }
        for (col in 0 until imageWidth) {
            if (horizonY[col] < 0) continue
            var v = horizonY[col]
            if (erasing) {
                if (knownSkyFloor[col] >= 0) v = max(v, knownSkyFloor[col])
                if (knownGroundCeiling[col] >= 0) v = min(v, knownGroundCeiling[col] - 1)
            } else {
                if (knownGroundCeiling[col] >= 0) v = min(v, knownGroundCeiling[col] - 1)
                if (knownSkyFloor[col] >= 0) v = max(v, knownSkyFloor[col])
            }
            horizonY[col] = v.coerceIn(0, imageHeight - 1)
        }
        for (i in 0 until imageWidth) solvedHorizon[i] = horizonY[i]
        bump()
    }

    /**
     * Move from band selection straight to refinement using a detected per-column horizon (macOS
     * `transitionToRefinement`): seed [horizonY], init the known regions from the band, edge-fill.
     */
    fun transitionToRefinement(horizon: List<Int>) {
        val filled = fillEdgeNils(horizon)
        for (i in 0 until imageWidth) horizonY[i] = if (i < filled.size) filled[i] else -1
        for (i in 0 until imageWidth) {
            knownSkyFloor[i] = bandTop[i]
            knownGroundCeiling[i] = bandBottom[i]
        }
        for (i in 0 until imageWidth) solvedHorizon[i] = horizonY[i]
        phase = HorizonPhase.REFINEMENT
        preStrokeHorizon = null
        // The band's strokes are spent: the gui drops them here, so a change of frame is not asked about until a refinement stroke.
        hasStrokes = false
        resetGesture()
        endStroke()
        bump()
    }

    /**
     * Seed an existing horizon (re-opening a frame that already has one): synthesize a ±[margin] band
     * around it and jump to refinement (macOS `loadExistingHorizon`).
     */
    fun loadExistingHorizon(horizon: List<Int>, margin: Int) {
        for (i in 0 until imageWidth) {
            val y = if (i < horizon.size) horizon[i] else -1
            if (y >= 0) {
                bandTop[i] = max(0, y - margin)
                bandBottom[i] = min(imageHeight - 1, y + margin)
            } else {
                bandTop[i] = -1
                bandBottom[i] = -1
            }
        }
        fillEdgeNilsInPlace(bandTop)
        fillEdgeNilsInPlace(bandBottom)
        transitionToRefinement(horizon)
    }

    /** Reset to a fresh band-selection pass (macOS `clear` / the Reset button). Keeps [brushRadius]. */
    fun clear() {
        for (i in 0 until imageWidth) {
            bandTop[i] = -1; bandBottom[i] = -1
            knownSkyFloor[i] = -1; knownGroundCeiling[i] = -1
            horizonY[i] = -1
            solvedHorizon[i] = -1
        }
        phase = HorizonPhase.BAND_SELECTION
        hasStrokes = false
        preStrokeHorizon = null
        gen++
        resetGesture()
        endStroke()
        bump()
    }

    /**
     * Reset per-frame paint data for a new frame while preserving the brush size and sky/ground mode
     * (macOS `resetForNewFrame`). Lands on [HorizonPhase.COMPUTING] while the view loads any existing
     * horizon asynchronously. The mode lasts as far as the phase the load settles on: a frame with a saved horizon goes to
     * refinement and keeps it, one that has to be banded from scratch goes to band selection, which puts it back on Sky.
     */
    fun resetForNewFrame() {
        val erasing = isErasing
        clear()   // leaves the brush size alone, and puts the mode back on Sky with the band selection it starts
        phase = HorizonPhase.COMPUTING
        isErasing = erasing
        bump()
    }

    companion object {
        // macOS HorizonPaintState: radius in image pixels, adjusted by 10 between 5 and 500.
        const val DEFAULT_BRUSH = 250
        const val MIN_BRUSH = 5
        const val MAX_BRUSH = 500
        const val BRUSH_STEP = 10

        /** How far beyond a stroke's columns the solver is asked to re-solve (macOS fixed 20 px margin). */
        const val REFINE_MARGIN = 20

        private fun fillEdgeNils(arr: List<Int>): List<Int> {
            val out = arr.toIntArray()
            fillEdgeNilsInPlace(out)
            return out.toList()
        }

        private fun fillEdgeNilsInPlace(arr: IntArray) {
            val firstSet = arr.indexOfFirst { it >= 0 }
            if (firstSet < 0) return
            for (i in 0 until firstSet) arr[i] = arr[firstSet]
            val lastSet = arr.indexOfLast { it >= 0 }
            for (i in lastSet + 1 until arr.size) arr[i] = arr[lastSet]
        }
    }
}
