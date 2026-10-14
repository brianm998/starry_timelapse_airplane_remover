package com.star.desktop.ui.sequence.edit

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.utf16CodePoint
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerIcon
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.input.pointer.pointerHoverIcon
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.toSize
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.proto.HorizonBandMethod
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.launch
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import com.star.desktop.i18n.localized

/**
 * Reference-horizon painter (macOS `HorizonPainterView` + `HorizonPainterToolbarView`). The user
 * brushes a band over the horizon; once it spans the frame the daemon runs the combined detector,
 * then sky/ground brushes refine the result via the random-walker — the same StarCore logic the
 * macOS app uses, reached over the `Horizon.ComputeInBand` RPC.
 *
 * Layout mirrors macOS: a scaled canvas (image + yellow band / blue sky fill + marching ants + a
 * brush-size cursor ring), a startup-only instruction tip at the top, and the phase-aware control
 * bar **below** the frame.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun HorizonPainterView(app: AppViewModel, vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val current by vm.currentIndex.collectAsState()
    val bmp by vm.currentPreview.collectAsState()
    val imgW = vm.info.imageWidth
    val imgH = vm.info.imageHeight

    // The paint state persists across frame advances so brush size and Sky/Ground mode survive
    // (macOS resetForNewFrame); per-frame paint data is cleared in the LaunchedEffect below. The
    // transform is the session's: the zoom and pan are the same here as in the edit view.
    val state = remember { HorizonPaintState(imgW, imgH).also { it.isErasing = vm.horizonPaintErasing.value } }
    // The sky/ground mode outlives this painter: it is remembered for the next time it opens.
    LaunchedEffect(state) { snapshotFlow { state.isErasing }.collect { vm.setHorizonPaintErasing(it) } }
    val transform = vm.transform
    var canvasSize by remember { mutableStateOf(Size.Zero) }
    var hover by remember { mutableStateOf<Offset?>(null) } // canvas-space pointer for the brush ring
    var dragging by remember { mutableStateOf(false) }      // a stroke is being painted: the ants hold still
    var refining by remember { mutableStateOf(0) }          // in-flight random-walker passes
    var errorText by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }          // a save is in flight: a second must not start (macOS isSaving)
    // The max-downward-extension stepper's value for the sequence: as stored (0 = derived) and as in force.
    var maxDownward by remember { mutableStateOf(MaxDownward(0, 0)) }
    LaunchedEffect(Unit) {
        app.horizonRepo.tunedParameters(vm.sessionId)?.let { maxDownward = MaxDownward(it.maxDownwardExtension, it.effectiveMaxDownwardExtension) }
    }
    var applyToNearby by remember { mutableStateOf(true) }   // macOS applyToNearbyFrames: on until turned off
    var savedAlready by remember { mutableStateOf(false) }    // the horizon on screen is already the saved one
    var cancelledExplicitly by remember { mutableStateOf(false) } // Cancel / Esc: the one way out that discards

    val startup by vm.horizonPainterStartup.collectAsState()
    val startupIndices by vm.startupHorizonIndices.collectAsState()
    val startupPos by vm.startupHorizonPosition.collectAsState()

    // All daemon compute for the current frame is parented to this job, cancelled when the frame
    // changes (or the painter closes) so a late detect/refine never mutates the next frame's state.
    val frameJob = remember(current) { SupervisorJob() }
    DisposableEffect(current) { onDispose { frameJob.cancel() } }

    // Closing the painter any way but Cancel keeps the work (macOS saves in `onDisappear`): H, leaving edit mode, the
    // panel button. Only a refined horizon is worth saving (band selection has none), and the startup flow has its own
    // Continue / Cancel. Launched in the view model's scope: this composable's own dies with it.
    DisposableEffect(Unit) {
        onDispose {
            val index = vm.currentIndex.value
            if (shouldSaveOnClose(vm.horizonPainterStartup.value, state.phase, savedAlready, cancelledExplicitly, saving)) {
                vm.saveHorizonReferenceInBackground(index, state.solvedHorizonSnapshot(), imgW, imgH)
            }
        }
    }

    // Seed any existing horizon (reference > merged > raw) → jump to refinement; else band selection.
    LaunchedEffect(current) {
        refining = 0
        errorText = null
        hover = null
        savedAlready = false
        state.resetForNewFrame()
        val existing = runCatching { app.horizonRepo.bestExisting(vm.sessionId, current, imgW, imgH) }.getOrNull()
        if (existing != null && existing.any { it >= 0 }) {
            state.loadExistingHorizon(existing, margin = max(50, imgH / 10))
        } else {
            state.phase = HorizonPhase.BAND_SELECTION
        }
    }

    // Initial band detection (macOS triggerBandComputation): runs once the band spans the frame.
    // The caller sets phase = COMPUTING synchronously before launching this.
    suspend fun runBandDetection(frameIdx: Int) {
        errorText = null
        val gen = state.generation()
        val result = app.horizonRepo.computeInBand(
            vm.sessionId, frameIdx, HorizonBandMethod.HORIZON_BAND_METHOD_COMBINED_SIOX,
            imgW, imgH, state.bandTopSnapshot(), state.bandBottomSnapshot(),
        )
        // Discard if the frame advanced or the paint was reset while the detector ran (shared state).
        if (vm.currentIndex.value != frameIdx || state.generation() != gen) return
        if (result != null && result.any { it >= 0 }) {
            state.transitionToRefinement(result)
        } else {
            errorText = localized("ui.horizon_detection_failed_adjust_the_band_and_try_again")
            state.phase = HorizonPhase.BAND_SELECTION
        }
    }

    // Refinement (macOS triggerObjectSelection): re-solve the random-walker over the brushed columns.
    suspend fun runRefine(frameIdx: Int, brush: IntRange, erasing: Boolean, baseline: IntArray?) {
        val margin = HorizonPaintState.REFINE_MARGIN
        val expanded = max(0, brush.first - margin)..min(imgW - 1, brush.last + margin)
        val inputs = state.localBand(expanded, brush, erasing, taperWidth = max(1, margin / 2))
        val gen = state.generation()
        refining++
        errorText = null
        try {
            val result = app.horizonRepo.computeInBand(
                vm.sessionId, frameIdx, HorizonBandMethod.HORIZON_BAND_METHOD_RANDOM_WALKER,
                imgW, imgH, inputs.top, inputs.bottom, inputs.skyFloor, inputs.groundCeiling,
            )
            // Discard if the frame advanced or the paint was reset while the walker ran (shared state).
            if (vm.currentIndex.value != frameIdx || state.generation() != gen) return
            if (result != null) {
                state.applyRefinedHorizon(result, expanded, baseline, erasing)
            } else {
                // Show the horizon the solver last gave, not the stroke's optimistic nudge that it did not confirm.
                state.restoreSolvedHorizon()
                errorText = localized("ui.refinement_failed_try_another_stroke")
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Throwable) {
            state.restoreSolvedHorizon()
            errorText = localized("ui.refinement_failed_try_another_stroke")
        } finally {
            refining = max(0, refining - 1)
        }
    }

    /**
     * Save the painted horizon as frame [frameIdx]'s reference. True only if the daemon took it: on a failure the
     * painter stays open and says why (macOS `saveError`), and nothing that follows a save (closing, advancing to
     * the next startup frame) happens for a horizon that was not saved. In the startup flow the save also marks the
     * sequence as having a static reference horizon; outside it, an edit to one frame's horizon must not.
     */
    suspend fun saveReference(frameIdx: Int): Boolean {
        val y = state.solvedHorizonSnapshot()   // what the solver produced, not the interim shape a stroke is showing
        if (saving || y.none { it >= 0 }) return false
        saving = true
        errorText = null
        return try {
            app.horizonRepo.setReference(vm.sessionId, frameIdx, y, imgW, imgH, setStaticReference = startup)
            savedAlready = true
            true
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Throwable) {
            errorText = e.message ?: e.toString()
            false
        } finally {
            saving = false
        }
    }

    // A transparent cursor so only our brush ring is visible while painting.
    val blankCursor = remember {
        PointerIcon(
            java.awt.Toolkit.getDefaultToolkit().createCustomCursor(
                java.awt.image.BufferedImage(16, 16, java.awt.image.BufferedImage.TYPE_INT_ARGB),
                java.awt.Point(0, 0), "blank",
            ),
        )
    }

    // Marching-ants dash animation (drives only the dash phase — the area path is memoized below).
    val antsT = rememberInfiniteTransition(label = "ants")
    val antsPhase by antsT.animateFloat(
        initialValue = 0f, targetValue = ANT_DASH * 2f,
        animationSpec = infiniteRepeatable(tween(durationMillis = 600, easing = LinearEasing), RepeatMode.Restart),
        label = "antsPhase",
    )

    // Rebuild the band/sky polygon only when the paint changes, the canvas resizes, or the phase
    // flips — NOT every 60fps animation tick (the ants animation just re-strokes this prebuilt path).
    val areaPath = remember(state.version, canvasSize, state.phase, transform.userZoom, transform.pan) {
        if (canvasSize == Size.Zero) null else buildAreaPath(state, transform, canvasSize)
    }
    val fillColor = if (state.phase == HorizonPhase.REFINEMENT) StarColors.blue.copy(alpha = 0.30f) else StarColors.yellow.copy(alpha = 0.28f)

    // What the buttons do, also what Return, Esc and R do from the keyboard.
    val doReset = { frameJob.cancelChildren(); refining = 0; state.clear() }
    val doSave = {
        val frameIdx = current
        scope.launch {
            if (saveReference(frameIdx)) {
                // With "apply to nearby frames" the daemon marks the frames that interpolate from this reference and the
                // sequence screen asks whether to redo them now (the painter closes, so it cannot host the question).
                vm.horizonReferenceSaved(frameIdx, applyToNearby)
                if (!startup) vm.toggleHorizonPaint()
            }
        }
        Unit
    }
    val doContinue = {
        val frameIdx = current
        scope.launch {
            if (saveReference(frameIdx)) app.startupHorizonAdvanceOrContinue()
        }
        Unit
    }
    val doCancel = {
        cancelledExplicitly = true
        if (startup) app.cancelStartupHorizon() else vm.toggleHorizonPaint()
    }

    // Keyboard: the brush and the mode without the pointer leaving the frame, as on macOS. The root takes the focus so the
    // keys are heard without a click first; the menu's own accelerators for these letters are disabled while painting
    // (Compose delivers an accelerator before it delivers the key to the view).
    val keyFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { keyFocus.requestFocus() } }
    val keyHandler = Modifier.onPreviewKeyEvent { event ->
        val action = painterKeyAction(event) ?: return@onPreviewKeyEvent false
        when (action) {
            HorizonPainterKey.SHRINK_BRUSH -> state.shrinkBrush()
            HorizonPainterKey.GROW_BRUSH -> state.growBrush()
            HorizonPainterKey.TOGGLE_MODE -> if (state.phase == HorizonPhase.REFINEMENT) state.isErasing = !state.isErasing
            HorizonPainterKey.SKY -> if (state.phase == HorizonPhase.REFINEMENT) state.isErasing = false
            HorizonPainterKey.GROUND -> if (state.phase == HorizonPhase.REFINEMENT) state.isErasing = true
            HorizonPainterKey.RESET -> if (state.phase == HorizonPhase.REFINEMENT || state.hasBand()) doReset()
            HorizonPainterKey.CANCEL -> doCancel()
            HorizonPainterKey.SAVE ->
                if (canSaveHorizon(state.phase, state.hasSolvedHorizon(), refining, saving)) { if (startup) doContinue() else doSave() }
        }
        true
    }

    Column(modifier.fillMaxSize().background(StarColors.appBackground).focusRequester(keyFocus).focusable().then(keyHandler)) {
        Box(
            Modifier.weight(1f).fillMaxSize()
                .clipToBounds()
                .onSizeChanged { canvasSize = it.toSize(); transform.canvasChanged(canvasSize) }
                // Scroll pans, Ctrl/Cmd-scroll zooms, middle- or Alt-drag pans (as in the edit view): the horizon can be
                // painted precisely at a zoom where the brush is a few pixels. A pan drag is consumed before it gets to
                // the painting gesture below, which only takes unconsumed presses.
                .zoomAndPan(transform) { canvasSize }
                .pointerHoverIcon(blankCursor)
                .onPointerEvent(PointerEventType.Move) { hover = it.changes.firstOrNull()?.position }
                .onPointerEvent(PointerEventType.Enter) { hover = it.changes.firstOrNull()?.position }
                .onPointerEvent(PointerEventType.Exit) { hover = null }
                .pointerInput(current, canvasSize) {
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = true)
                        hover = down.position
                        dragging = true
                        // Paint on the initial press so a single click/tap dabs paint (macOS uses
                        // DragGesture(minimumDistance: 0); detectDragGestures would swallow taps).
                        if (state.phase != HorizonPhase.COMPUTING) {
                            errorText = null // resuming painting clears any stale detection error
                            state.beginStroke()
                            val img = transform.canvasToImage(down.position, canvasSize)
                            state.paint(img.x.roundToInt(), img.y.roundToInt())
                        }
                        down.consume()
                        do {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull()
                            if (change != null) {
                                hover = change.position
                                if (change.pressed && state.phase != HorizonPhase.COMPUTING) {
                                    val img = transform.canvasToImage(change.position, canvasSize)
                                    state.paint(img.x.roundToInt(), img.y.roundToInt())
                                    change.consume()
                                }
                            }
                        } while (event.changes.any { it.pressed })
                        dragging = false

                        // Stroke ended → trigger detection / refinement.
                        when (state.phase) {
                            HorizonPhase.BAND_SELECTION -> {
                                state.endStroke()
                                if (state.isBandComplete) {
                                    // Flip to COMPUTING synchronously (macOS HorizonPainterView.swift:211) so a
                                    // re-entrant gesture can't keep painting the band or launch a second detect.
                                    state.phase = HorizonPhase.COMPUTING
                                    scope.launch(frameJob) { runBandDetection(current) }
                                }
                            }
                            HorizonPhase.REFINEMENT -> {
                                val range = state.lastGestureRange()
                                val erasing = state.isErasing
                                val baseline = state.preStrokeBaseline()
                                state.endStroke()
                                if (range != null) {
                                    state.commitRefinementGesture(erasing)
                                    scope.launch(frameJob) { runRefine(current, range, erasing, baseline) }
                                }
                            }
                            HorizonPhase.COMPUTING -> state.endStroke()
                        }
                    }
                },
        ) {
            Canvas(Modifier.fillMaxSize()) {
                val s = transform.scale(size)
                val o = transform.origin(size)
                bmp?.let { img ->
                    drawImage(
                        image = img,
                        srcOffset = IntOffset.Zero,
                        srcSize = IntSize(img.width, img.height),
                        dstOffset = IntOffset(o.x.roundToInt(), o.y.roundToInt()),
                        dstSize = IntSize((imgW * s).roundToInt(), (imgH * s).roundToInt()),
                    )
                }
                areaPath?.let { path ->
                    drawPath(path, fillColor)
                    // Marching ants: white dashes with offset black dashes between them.
                    // Not reading the animated phase while dragging is what stops it redrawing every tick: the outline still
                    // follows the brush, but the dashes do not crawl over a shape that changes with every event.
                    val phase = if (dragging) 0f else antsPhase
                    drawPath(path, Color.White, style = Stroke(width = 1.6f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(ANT_DASH, ANT_DASH), phase)))
                    drawPath(path, Color.Black, style = Stroke(width = 1.6f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(ANT_DASH, ANT_DASH), phase + ANT_DASH)))
                }
                hover?.let { drawBrushCursor(it, state.brushRadius * s, cursorColor(state, refining > 0)) }
            }

            // What the pointer would do, beside the brush ring (macOS draws it to the ring's upper right).
            hover?.let { at ->
                val ringR = state.brushRadius * transform.scale(canvasSize)
                Text(
                    cursorLabel(state, refining > 0),
                    color = cursorColor(state, refining > 0),
                    fontSize = 11.sp,
                    modifier = Modifier.offset { IntOffset((at.x + ringR + 6f).roundToInt(), (at.y - ringR - 22f).roundToInt()) },
                )
            }

            // Instruction tip overlays the top of the frame (startup only; macOS parity).
            if (startup) {
                HorizonInstructionTip(app.prefs, isMoving = startupIndices.size > 1, modifier = Modifier.align(Alignment.TopCenter))
            }
        }

        HorizonControlBar(
            state = state,
            startup = startup, startupIndices = startupIndices, startupPos = startupPos,
            refining = refining, saving = saving, errorText = errorText,
            applyToNearby = applyToNearby, onApplyToNearbyChange = { applyToNearby = it },
            maxDownward = maxDownward,
            onMaxDownwardStep = { delta ->
                val next = nextMaxDownwardExtension(maxDownward, delta)
                // Shown at once; what the daemon answers (the effective value in force) is what stays.
                maxDownward = maxDownward.copy(configured = next)
                scope.launch {
                    runCatching { app.horizonRepo.setMaxDownwardExtension(vm.sessionId, next) }
                        .onSuccess { maxDownward = MaxDownward(it.maxDownwardExtension, it.effectiveMaxDownwardExtension) }
                }
            },
            onReset = doReset,
            onSave = doSave,
            onContinue = doContinue,
            onCancel = doCancel,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

private const val ANT_DASH = 6f

/** What a key does in the horizon painter (macOS `brushKeyboardHandlers` and `actionKeyboardHandlers`). */
internal enum class HorizonPainterKey { SHRINK_BRUSH, GROW_BRUSH, TOGGLE_MODE, SKY, GROUND, RESET, CANCEL, SAVE }

/**
 * The painter's action for [event], or null if the key is not one of its own (it then goes on to the rest of the window).
 * `[` / `]` size the brush, `-` flips sky and ground, `p` is sky, `e` ground, `r` starts over, Esc cancels and Return saves
 * (the caller applies the same conditions as the button). Only on key-down, and never with Ctrl, Cmd or Alt held, which
 * are other shortcuts' business. The bracket keys are matched by the character they type as well as by their key, since a
 * layout that needs a modifier for them reports a different key.
 */
@OptIn(ExperimentalComposeUiApi::class)
internal fun painterKeyAction(event: KeyEvent): HorizonPainterKey? {
    if (event.type != KeyEventType.KeyDown) return null
    if (event.isCtrlPressed || event.isMetaPressed || event.isAltPressed) return null
    val typed = event.utf16CodePoint
    return when {
        event.key == Key.LeftBracket || typed == '['.code -> HorizonPainterKey.SHRINK_BRUSH
        event.key == Key.RightBracket || typed == ']'.code -> HorizonPainterKey.GROW_BRUSH
        event.key == Key.Minus || typed == '-'.code -> HorizonPainterKey.TOGGLE_MODE
        event.key == Key.P -> HorizonPainterKey.SKY
        event.key == Key.E -> HorizonPainterKey.GROUND
        event.key == Key.R -> HorizonPainterKey.RESET
        event.key == Key.Escape -> HorizonPainterKey.CANCEL
        event.key == Key.Enter || event.key == Key.NumPadEnter -> HorizonPainterKey.SAVE
        else -> null
    }
}

/**
 * Whether closing the painter should save what is on it (macOS `onDisappear`): only outside the startup flow (which
 * has its own Continue / Cancel), only from refinement (band selection has no horizon yet), and only if the user did
 * not cancel, it is not already saved, and a save is not already running.
 */
internal fun shouldSaveOnClose(startup: Boolean, phase: HorizonPhase, savedAlready: Boolean, cancelled: Boolean, saving: Boolean): Boolean =
    !startup && phase == HorizonPhase.REFINEMENT && !savedAlready && !cancelled && !saving

/**
 * Whether the painted horizon may be saved right now (macOS `canSave`): refinement has produced one, no refinement
 * pass is still running (a save then would store the horizon from before it), and no save is already under way (two
 * at once advanced two startup frames for one horizon).
 */
internal fun canSaveHorizon(phase: HorizonPhase, hasHorizon: Boolean, refining: Int, saving: Boolean): Boolean =
    phase == HorizonPhase.REFINEMENT && hasHorizon && refining == 0 && !saving

private fun cursorColor(state: HorizonPaintState, refining: Boolean): Color = when (state.phase) {
    HorizonPhase.BAND_SELECTION -> StarColors.yellow
    HorizonPhase.COMPUTING -> StarColors.gray
    HorizonPhase.REFINEMENT -> if (refining) StarColors.gray else if (state.isErasing) StarColors.red else StarColors.green
}

/** What the brush is for right now, in words (macOS cursor label); grey and "Calculating..." while the solver runs. */
private fun cursorLabel(state: HorizonPaintState, refining: Boolean): String = when (state.phase) {
    HorizonPhase.BAND_SELECTION -> localized("ui.select_area_with_horizon")
    HorizonPhase.COMPUTING -> localized("ui.calculating")
    HorizonPhase.REFINEMENT -> when {
        refining -> localized("ui.calculating")
        state.isErasing -> localized("ui.select_ground")
        else -> localized("ui.select_sky")
    }
}

private fun DrawScope.drawBrushCursor(center: Offset, radius: Float, color: Color) {
    val r = radius.coerceAtLeast(2f)
    drawCircle(Color.Black.copy(alpha = 0.5f), radius = r, center = center, style = Stroke(width = 3f))
    drawCircle(color, radius = r, center = center, style = Stroke(width = 1.5f))
    drawCircle(color, radius = 2.5f, center = center)
}

// ---- area-path builder (image-column runs → a canvas-space polygon) ----

/**
 * Build the fill/outline polygon for the current phase in canvas space: the painted band (top↔bottom
 * ribbon) during band selection, or the detected sky (image-top → horizon) during refinement. Returns
 * null when nothing is painted. Disjoint painted runs become separate sub-paths.
 */
private fun buildAreaPath(state: HorizonPaintState, transform: FrameTransform, canvas: Size): Path? {
    val refine = state.phase == HorizonPhase.REFINEMENT
    val valueAt: (Int) -> Int = if (refine) state::horizonAt else state::bandTopAt
    val runs = runsOf(state.imageWidth, valueAt)
    if (runs.isEmpty()) return null
    fun toCanvas(x: Int, y: Int) = transform.imageToCanvas(Offset(x.toFloat(), y.toFloat()), canvas)
    return Path().apply {
        for (run in runs) {
            val first = run.first
            val last = run.last
            if (refine) {
                toCanvas(first, 0).let { moveTo(it.x, it.y) }       // image top-left
                toCanvas(last, 0).let { lineTo(it.x, it.y) }        // image top-right
                for (c in last downTo first) toCanvas(c, state.horizonAt(c)).let { lineTo(it.x, it.y) }
            } else {
                toCanvas(first, state.bandTopAt(first)).let { moveTo(it.x, it.y) }
                for (c in first..last) toCanvas(c, state.bandTopAt(c)).let { lineTo(it.x, it.y) }
                for (c in last downTo first) toCanvas(c, state.bandBottomAt(c)).let { lineTo(it.x, it.y) }
            }
            close()
        }
    }
}

/** Contiguous column runs [first..last] where [valueAt] is set (>= 0). */
private inline fun runsOf(width: Int, valueAt: (Int) -> Int): List<IntRange> {
    val runs = ArrayList<IntRange>()
    var x = 0
    while (x < width) {
        if (valueAt(x) < 0) { x++; continue }
        val start = x
        while (x < width && valueAt(x) >= 0) x++
        runs.add(start until x)
    }
    return runs
}

// ---- instruction tip (startup only; macOS HorizonPainterStartupInstructionsView) ----

@Composable
private fun HorizonInstructionTip(prefs: com.star.desktop.data.LocalPreferences, isMoving: Boolean, modifier: Modifier = Modifier) {
    var dismissed by remember { mutableStateOf(false) }
    var dontShowAgain by remember { mutableStateOf(false) }
    // The preference outlives this session; Preferences turns it back on (macOS showHorizonPainterInstructions).
    if (dismissed || !prefs.showHorizonPainterInstructions) return
    Column(
        modifier
            .padding(top = 12.dp, start = 20.dp, end = 20.dp)
            .widthIn(max = 720.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.Black.copy(alpha = 0.78f))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(localized("ui.selecting_the_horizon_with_star_is_easy"), color = Color.White, fontSize = 15.sp)
        Text(
            localized(if (isMoving) "ui.horizon_painter_instructions_moving" else "ui.horizon_painter_instructions_static") + "\n\n" +
                localized("ui.horizon_painter_instructions_brushing"),
            color = StarColors.textSecondary, fontSize = 12.sp,
        )
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.End) {
            androidx.compose.material3.Checkbox(checked = dontShowAgain, onCheckedChange = { dontShowAgain = it })
            Text(localized("ui.don_t_show_again"), color = Color.White, fontSize = 12.sp)
            Spacer(Modifier.size(16.dp))
            OutlinedButton(onClick = {
                if (dontShowAgain) prefs.showHorizonPainterInstructions = false
                dismissed = true
            }) { Text(localized("ui.got_it")) }
        }
    }
}

// ---- phase-aware control bar (below the frame; macOS HorizonPainterToolbarView) ----

@Composable
private fun HorizonControlBar(
    state: HorizonPaintState,
    startup: Boolean,
    startupIndices: List<Int>,
    startupPos: Int,
    refining: Int,
    saving: Boolean,
    errorText: String?,
    applyToNearby: Boolean,
    onApplyToNearbyChange: (Boolean) -> Unit,
    maxDownward: MaxDownward,
    onMaxDownwardStep: (Int) -> Unit,
    onReset: () -> Unit,
    onSave: () -> Unit,
    onContinue: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // Observe paint mutations so coverage %, the Continue button, etc. recompose live.
    val v = state.version
    val phase = state.phase
    val coverage = v.let { (state.bandCoverage * 100).roundToInt() }
    val hasHorizon = v.let { state.hasSolvedHorizon() }
    val hasMore = startupIndices.isNotEmpty() && startupPos + 1 < startupIndices.size
    val canSave = canSaveHorizon(phase, hasHorizon, refining, saving)

    Row(
        modifier
            .padding(16.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(StarColors.sidePanel.copy(alpha = 0.95f))
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (startup && startupIndices.size > 1) {
            Text("${startupPos + 1} / ${startupIndices.size}", color = StarColors.textSecondary, fontSize = 12.sp)
        }

        if (phase == HorizonPhase.COMPUTING) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = StarColors.accent)
            Text(localized("ui.computing_horizon"), color = StarColors.textSecondary, fontSize = 12.sp)
            Spacer(Modifier.weight(1f))
            OutlinedButton(onClick = onCancel) { Text(localized("ui.cancel")) }
            return@Row
        }

        BrushSizeControl(state)

        if (phase == HorizonPhase.REFINEMENT) {
            DividerDot()
            SkyGroundToggle(state)
        } else {
            DividerDot()
            Text(localized("ui.paint_across_horizon", coverage), color = StarColors.yellow, fontSize = 12.sp)
        }

        if (phase == HorizonPhase.REFINEMENT) {
            DividerDot()
            MaxDownwardExtensionControl(maxDownward, onMaxDownwardStep)
        }

        if (!startup && phase == HorizonPhase.REFINEMENT) {
            DividerDot()
            Row(verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.material3.Switch(checked = applyToNearby, onCheckedChange = onApplyToNearbyChange)
                Spacer(Modifier.size(6.dp))
                Text(localized("ui.apply_to_nearby_frames"), color = StarColors.textSecondary, fontSize = 11.sp)
            }
        }

        // Nothing to start over from until something is painted (macOS disables Reset in band selection until then).
        OutlinedButton(onClick = onReset, enabled = phase == HorizonPhase.REFINEMENT || v.let { state.hasBand() }) { Text(localized("ui.reset")) }

        Spacer(Modifier.weight(1f))

        if (refining > 0) {
            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = StarColors.accent)
            Text(localized("ui.detecting"), color = StarColors.textSecondary, fontSize = 11.sp)
        }
        errorText?.let { Text(it, color = StarColors.red, fontSize = 11.sp) }

        if (phase == HorizonPhase.REFINEMENT) {
            if (startup) {
                Button(
                    enabled = canSave,
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                    onClick = onContinue,
                ) { Text(localized(if (hasMore) "ui.next" else "ui.continue")) }
            } else {
                Button(
                    enabled = canSave,
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                    onClick = onSave,
                ) { Text(localized("ui.save")) }
            }
        }

        OutlinedButton(onClick = onCancel) { Text(localized("ui.cancel")) }
    }
}

@Composable
private fun BrushSizeControl(state: HorizonPaintState) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        OutlinedButton(
            onClick = { state.shrinkBrush() },
            enabled = state.brushRadius > state.minBrush,
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
        ) { Text("−") }
        Text("${state.brushRadius}px", color = StarColors.textSecondary, fontSize = 11.sp)
        OutlinedButton(
            onClick = { state.growBrush() },
            enabled = state.brushRadius < state.maxBrush,
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
        ) { Text("+") }
    }
}

/**
 * How far below the reference-derived line the brightness refinement may put the horizon (the "↓Npx" stepper). [configured] is
 * what is stored, 0 meaning "derive it from the refinement search radius"; [effective] is the number in force, which is what
 * is shown, so the readout is never a bare 0.
 */
internal data class MaxDownward(val configured: Int, val effective: Int)

/** The stored value after stepping by [delta] (macOS ±10): from the derived number on screen when nothing is stored, never below 0. */
internal fun nextMaxDownwardExtension(current: MaxDownward, delta: Int): Int {
    val base = if (current.configured > 0) current.configured else current.effective
    return maxOf(0, base + delta)
}

@Composable
private fun MaxDownwardExtensionControl(value: MaxDownward, onStep: (Int) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        OutlinedButton(
            onClick = { onStep(-MAX_DOWNWARD_STEP) },
            enabled = value.configured > 0,
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
        ) { Text("−") }
        Text(
            "↓${value.effective}px",
            color = if (value.configured > 0) StarColors.textSecondary else StarColors.textDisabled,
            fontSize = 11.sp,
        )
        OutlinedButton(
            onClick = { onStep(MAX_DOWNWARD_STEP) },
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
        ) { Text("+") }
    }
}

private const val MAX_DOWNWARD_STEP = 10

@Composable
private fun SkyGroundToggle(state: HorizonPaintState) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        if (!state.isErasing) {
            Button(onClick = { state.isErasing = false }, colors = ButtonDefaults.buttonColors(containerColor = StarColors.green)) { Text(localized("ui.sky"), color = Color.White) }
            OutlinedButton(onClick = { state.isErasing = true }) { Text(localized("ui.ground")) }
        } else {
            OutlinedButton(onClick = { state.isErasing = false }) { Text(localized("ui.sky")) }
            Button(onClick = { state.isErasing = true }, colors = ButtonDefaults.buttonColors(containerColor = StarColors.red)) { Text(localized("ui.ground"), color = Color.White) }
        }
    }
}

@Composable
private fun DividerDot() {
    Text("·", color = StarColors.textDisabled, fontSize = 14.sp)
}
