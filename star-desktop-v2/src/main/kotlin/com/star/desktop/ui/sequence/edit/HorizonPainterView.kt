package com.star.desktop.ui.sequence.edit

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.toSize
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import kotlinx.coroutines.launch
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import kotlin.math.roundToInt

/**
 * Reference-horizon painter (macOS `HorizonPainterView`): drag to paint the sky/ground boundary in
 * image space (reusing [FrameTransform], like the outlier overlay), then save it as the reference
 * horizon via `Horizon.SetReference` and optionally reprocess.
 */
@Composable
fun HorizonPainterView(app: AppViewModel, vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val current by vm.currentIndex.collectAsState()
    val bmp by vm.currentPreview.collectAsState()
    val imgW = vm.info.imageWidth
    val imgH = vm.info.imageHeight

    val state = remember(current) { HorizonPaintState(imgW, imgH) }
    val transform = remember(current) { FrameTransform(imgW, imgH) }
    var canvasSize by remember { mutableStateOf(Size.Zero) }
    var status by remember(current) { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    // Seed from an existing saved reference for this frame.
    LaunchedEffect(current) {
        app.horizonRepo.getReference(vm.sessionId, current)?.let { r ->
            if (r.exists && r.columns.horizonYCount > 0) state.seed(r.columns.horizonYList)
        }
    }

    Column(modifier.fillMaxSize().background(StarColors.appBackground)) {
        // Toolbar
        Row(
            Modifier.fillMaxWidth().background(StarColors.sidePanel.copy(alpha = 0.5f)).padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Horizon", color = StarColors.textPrimary, fontSize = 13.sp)
            Text("brush", color = StarColors.textDisabled, fontSize = 10.sp)
            Slider(
                value = state.brushRadius.toFloat(),
                onValueChange = { state.brushRadius = it.roundToInt().coerceAtLeast(1) },
                valueRange = 4f..(imgW / 8f).coerceAtLeast(8f),
                modifier = Modifier.width(140.dp),
            )
            Box(Modifier.weight(1f))
            status?.let { Text(it, color = StarColors.textSecondary, fontSize = 11.sp) }
            OutlinedButton(onClick = { state.clear() }, enabled = !busy) { Text("Clear") }
            OutlinedButton(
                enabled = !busy && state.hasAnyPaint(),
                onClick = { scope.launch { saveReference(app, vm, current, state, imgW, imgH, reprocess = false) { status = it; busy = it == "Saving…" } } },
            ) { Text("Save") }
            Button(
                enabled = !busy && state.hasAnyPaint(),
                colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                onClick = { scope.launch { busy = true; saveReference(app, vm, current, state, imgW, imgH, reprocess = true) { status = it }; busy = false } },
            ) { Text("Save & Reprocess") }
            OutlinedButton(onClick = { vm.toggleHorizonPaint() }, enabled = !busy) { Text("Done") }
        }

        Box(
            Modifier.weight(1f).fillMaxSize()
                .onSizeChanged { canvasSize = it.toSize() }
                .pointerInput(current) {
                    detectDragGestures(
                        onDragEnd = { state.endStroke() },
                        onDragCancel = { state.endStroke() },
                    ) { change, _ ->
                        val img = transform.canvasToImage(change.position, canvasSize)
                        state.paint(img.x.roundToInt(), img.y.roundToInt())
                        change.consume()
                    }
                },
        ) {
            Canvas(Modifier.fillMaxSize()) {
                val s = transform.scale(size)
                val o = transform.origin(size)
                val img = bmp
                if (img != null) {
                    drawImage(
                        image = img,
                        srcOffset = IntOffset.Zero,
                        srcSize = IntSize(img.width, img.height),
                        dstOffset = IntOffset(o.x.roundToInt(), o.y.roundToInt()),
                        dstSize = IntSize((imgW * s).roundToInt(), (imgH * s).roundToInt()),
                    )
                }
                state.version.let { } // observe (draw-phase subscription) so painting triggers redraw

                // Build the boundary polyline + sky fill from painted columns.
                val painted = ArrayList<Offset>(imgW)
                for (x in 0 until imgW) {
                    val y = state.yAt(x)
                    if (y >= 0) painted.add(transform.imageToCanvas(Offset(x.toFloat(), y.toFloat()), size))
                }
                if (painted.size >= 2) {
                    // Sky fill (above the boundary).
                    val fill = Path().apply {
                        moveTo(painted.first().x, 0f)
                        painted.forEach { lineTo(it.x, it.y) }
                        lineTo(painted.last().x, 0f)
                        close()
                    }
                    drawPath(fill, StarColors.blue.copy(alpha = 0.18f))
                    // Boundary line.
                    for (i in 1 until painted.size) {
                        drawLine(StarColors.green, painted[i - 1], painted[i], 2.5f)
                    }
                }
            }
        }
    }
}

private suspend fun saveReference(
    app: AppViewModel,
    vm: SequenceViewModel,
    frameIndex: Int,
    state: HorizonPaintState,
    imgW: Int,
    imgH: Int,
    reprocess: Boolean,
    onStatus: (String) -> Unit,
) {
    onStatus("Saving…")
    val ok = runCatching {
        app.horizonRepo.setReference(vm.sessionId, frameIndex, state.snapshot(), imgW, imgH, setStaticReference = true)
    }.isSuccess
    if (!ok) { onStatus("Save failed"); return }
    if (!reprocess) { onStatus("Saved"); return }

    onStatus("Reprocessing…")
    vm.processing.stop() // free the daemon's single progress slot
    runCatching { app.horizonRepo.reprocess(vm.sessionId, listOf(frameIndex)).collect { } }
    vm.processing.subscribe(vm.sessionId) // restore the live progress subscription
    onStatus("Reprocessed")
}
