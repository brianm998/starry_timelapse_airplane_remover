package com.star.desktop.ui.sequence.edit

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
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

    // The state + transform persist across frame advances so brush size and Sky/Ground mode survive
    // (macOS resetForNewFrame). Per-frame paint data is cleared in the LaunchedEffect below.
    val state = remember { HorizonPaintState(imgW, imgH) }
    val transform = remember { FrameTransform(imgW, imgH) }
    var canvasSize by remember { mutableStateOf(Size.Zero) }
    var hover by remember { mutableStateOf<Offset?>(null) } // canvas-space pointer for the brush ring
    var refining by remember { mutableStateOf(0) }          // in-flight random-walker passes
    var errorText by remember { mutableStateOf<String?>(null) }

    val startup by vm.horizonPainterStartup.collectAsState()
    val startupIndices by vm.startupHorizonIndices.collectAsState()
    val startupPos by vm.startupHorizonPosition.collectAsState()

    // All daemon compute for the current frame is parented to this job, cancelled when the frame
    // changes (or the painter closes) so a late detect/refine never mutates the next frame's state.
    val frameJob = remember(current) { SupervisorJob() }
    DisposableEffect(current) { onDispose { frameJob.cancel() } }

    // Seed any existing horizon (reference > merged > raw) → jump to refinement; else band selection.
    LaunchedEffect(current) {
        refining = 0
        errorText = null
        hover = null
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
            errorText = "Horizon detection failed — adjust the band and try again"
            state.phase = HorizonPhase.BAND_SELECTION
        }
    }

    // Refinement (macOS triggerObjectSelection): re-solve the random-walker over the brushed columns.
    suspend fun runRefine(frameIdx: Int, brush: IntRange, erasing: Boolean, baseline: IntArray?) {
        val margin = max(20, imgW / 100)
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
            if (result != null) state.applyRefinedHorizon(result, expanded, baseline)
            else errorText = "Refinement failed — try another stroke"
        } finally {
            refining = max(0, refining - 1)
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

    Column(modifier.fillMaxSize().background(StarColors.appBackground)) {
        Box(
            Modifier.weight(1f).fillMaxSize()
                .onSizeChanged { canvasSize = it.toSize() }
                .pointerHoverIcon(blankCursor)
                .onPointerEvent(PointerEventType.Move) { hover = it.changes.firstOrNull()?.position }
                .onPointerEvent(PointerEventType.Enter) { hover = it.changes.firstOrNull()?.position }
                .onPointerEvent(PointerEventType.Exit) { hover = null }
                .pointerInput(current, canvasSize) {
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        hover = down.position
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
                    drawPath(path, Color.White, style = Stroke(width = 1.6f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(ANT_DASH, ANT_DASH), antsPhase)))
                    drawPath(path, Color.Black, style = Stroke(width = 1.6f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(ANT_DASH, ANT_DASH), antsPhase + ANT_DASH)))
                }
                hover?.let { drawBrushCursor(it, state.brushRadius * s, cursorColor(state)) }
            }

            // Instruction tip overlays the top of the frame (startup only; macOS parity).
            if (startup) {
                HorizonInstructionTip(isMoving = startupIndices.size > 1, modifier = Modifier.align(Alignment.TopCenter))
            }
        }

        HorizonControlBar(
            state = state,
            startup = startup, startupIndices = startupIndices, startupPos = startupPos,
            refining = refining, errorText = errorText,
            onReset = { frameJob.cancelChildren(); refining = 0; state.clear() },
            onSave = { reprocess ->
                val frameIdx = current
                scope.launch {
                    val y = state.horizonSnapshot()
                    if (y.any { it >= 0 }) {
                        runCatching { app.horizonRepo.setReference(vm.sessionId, frameIdx, y, imgW, imgH, setStaticReference = true) }
                        if (reprocess) {
                            vm.processing.stop()
                            runCatching { app.horizonRepo.reprocess(vm.sessionId, listOf(frameIdx)).collect { } }
                            vm.processing.subscribe(vm.sessionId)
                        }
                    }
                    if (!startup) vm.toggleHorizonPaint()
                }
            },
            onContinue = {
                val frameIdx = current
                scope.launch {
                    val y = state.horizonSnapshot()
                    if (y.any { it >= 0 }) {
                        runCatching { app.horizonRepo.setReference(vm.sessionId, frameIdx, y, imgW, imgH, setStaticReference = true) }
                    }
                    app.startupHorizonAdvanceOrContinue()
                }
            },
            onCancel = { if (startup) app.cancelStartupHorizon() else vm.toggleHorizonPaint() },
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

private const val ANT_DASH = 6f

private fun cursorColor(state: HorizonPaintState): Color = when (state.phase) {
    HorizonPhase.BAND_SELECTION -> StarColors.yellow
    HorizonPhase.COMPUTING -> StarColors.gray
    HorizonPhase.REFINEMENT -> if (state.isErasing) StarColors.red else StarColors.green
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
private fun HorizonInstructionTip(isMoving: Boolean, modifier: Modifier = Modifier) {
    var dismissed by remember { mutableStateOf(false) }
    if (dismissed) return
    Column(
        modifier
            .padding(top = 12.dp, start = 20.dp, end = 20.dp)
            .widthIn(max = 720.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.Black.copy(alpha = 0.78f))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Selecting the horizon with Star is easy.", color = Color.White, fontSize = 15.sp)
        Text(
            (if (isMoving) {
                "For a moving video like this, define the horizon on several evenly-spaced frames; Star uses " +
                    "them as references for the whole sequence. "
            } else {
                "For a static video like this, pick any frame and Star applies that horizon to the whole " +
                    "sequence. "
            }) +
                "If this frame doesn't show the horizon well, scroll to a better one first. Then brush over " +
                "the horizon so the selected area covers the horizon line. Once you've selected across the " +
                "full width, Star detects the sky automatically. If it looks right, hit " +
                (if (isMoving) "Next/Continue" else "Continue") +
                ". Otherwise use the Sky and Ground brushes to add to or remove from the selection, and the " +
                "− / + buttons to resize the brush.",
            color = StarColors.textSecondary, fontSize = 12.sp,
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            OutlinedButton(onClick = { dismissed = true }) { Text("Got it") }
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
    errorText: String?,
    onReset: () -> Unit,
    onSave: (reprocess: Boolean) -> Unit,
    onContinue: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // Observe paint mutations so coverage %, the Continue button, etc. recompose live.
    val v = state.version
    val phase = state.phase
    val coverage = v.let { (state.bandCoverage * 100).roundToInt() }
    val hasHorizon = v.let { state.hasHorizon() }
    val hasMore = startupIndices.isNotEmpty() && startupPos + 1 < startupIndices.size

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
            Text("Computing horizon…", color = StarColors.textSecondary, fontSize = 12.sp)
            Spacer(Modifier.weight(1f))
            OutlinedButton(onClick = onCancel) { Text(if (startup) "Cancel" else "Done") }
            return@Row
        }

        BrushSizeControl(state)

        if (phase == HorizonPhase.REFINEMENT) {
            DividerDot()
            SkyGroundToggle(state)
        } else {
            DividerDot()
            Text("Paint across the horizon — $coverage%", color = StarColors.yellow, fontSize = 12.sp)
        }

        OutlinedButton(onClick = onReset) { Text("Reset") }

        Spacer(Modifier.weight(1f))

        if (refining > 0) {
            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = StarColors.accent)
            Text("Detecting…", color = StarColors.textSecondary, fontSize = 11.sp)
        }
        errorText?.let { Text(it, color = StarColors.red, fontSize = 11.sp) }

        if (phase == HorizonPhase.REFINEMENT) {
            if (startup) {
                Button(
                    enabled = hasHorizon && refining == 0,
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                    onClick = onContinue,
                ) { Text(if (hasMore) "Next" else "Continue") }
            } else {
                OutlinedButton(enabled = hasHorizon && refining == 0, onClick = { onSave(false) }) { Text("Save") }
                Button(
                    enabled = hasHorizon && refining == 0,
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                    onClick = { onSave(true) },
                ) { Text("Save & Reprocess") }
            }
        }

        OutlinedButton(onClick = onCancel) { Text(if (startup) "Cancel" else "Done") }
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

@Composable
private fun SkyGroundToggle(state: HorizonPaintState) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        if (!state.isErasing) {
            Button(onClick = { state.isErasing = false }, colors = ButtonDefaults.buttonColors(containerColor = StarColors.green)) { Text("Sky", color = Color.White) }
            OutlinedButton(onClick = { state.isErasing = true }) { Text("Ground") }
        } else {
            OutlinedButton(onClick = { state.isErasing = false }) { Text("Sky") }
            Button(onClick = { state.isErasing = true }, colors = ButtonDefaults.buttonColors(containerColor = StarColors.red)) { Text("Ground", color = Color.White) }
        }
    }
}

@Composable
private fun DividerDot() {
    Text("·", color = StarColors.textDisabled, fontSize = 14.sp)
}
