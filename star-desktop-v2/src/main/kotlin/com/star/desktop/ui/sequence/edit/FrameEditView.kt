package com.star.desktop.ui.sequence.edit

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.toSize
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import kotlin.math.roundToInt

/**
 * Edit-mode center view (macOS `FrameEditView` + `OutlierGroupView`): the frame image with
 * scroll-to-zoom / drag-to-pan, the outlier overlay, and click hit-testing — all driven by one
 * [FrameTransform] so they stay aligned at every zoom/pan.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun FrameEditView(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val current by vm.currentIndex.collectAsState()
    val fvm = remember(current) { vm.frameVMFor(current) }
    LaunchedEffect(current) { fvm.load() }

    val bmp by vm.currentPreview.collectAsState()
    val tool by vm.tool.collectAsState()
    val groups by fvm.groups.collectAsState()
    val decisions by fvm.decisions.collectAsState()
    val selected by fvm.selected.collectAsState()
    val labelMap by fvm.labelMap.collectAsState()

    val transform = remember(current) { FrameTransform(vm.info.imageWidth, vm.info.imageHeight) }
    var canvasSize by remember { mutableStateOf(Size.Zero) }

    Box(
        modifier
            .fillMaxSize()
            .background(StarColors.appBackground)
            .onSizeChanged { canvasSize = it.toSize() }
            .onPointerEvent(PointerEventType.Scroll) { ev ->
                val change = ev.changes.firstOrNull() ?: return@onPointerEvent
                val dy = change.scrollDelta.y
                if (dy != 0f) {
                    transform.zoomBy(if (dy < 0) 1.1f else 1f / 1.1f, change.position, canvasSize)
                    change.consume()
                }
            }
            .pointerInput(Unit) {
                detectDragGestures { change, drag ->
                    transform.panBy(drag)
                    change.consume()
                }
            }
            .pointerInput(tool, labelMap, groups) {
                detectTapGestures { pos ->
                    val map = labelMap ?: return@detectTapGestures
                    val img = transform.canvasToImage(pos, canvasSize)
                    val gid = map.idAt(img.x.roundToInt(), img.y.roundToInt())
                    if (gid > 0) fvm.applyTool(gid, tool)
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
                    dstSize = IntSize((vm.info.imageWidth * s).roundToInt(), (vm.info.imageHeight * s).roundToInt()),
                )
            }
            // Outlier overlay — colors per current decision (macOS OutlierGroupView opacities).
            for (g in groups) {
                val reason = decisions[g.id] ?: g.shouldRemove
                val isSel = selected == g.id
                val color = StarColors.groupColor(reason, isSel)
                val tl = transform.imageToCanvas(Offset(g.bounds.minX.toFloat(), g.bounds.minY.toFloat()), size)
                val br = transform.imageToCanvas(Offset(g.bounds.maxX.toFloat(), g.bounds.maxY.toFloat()), size)
                val boxSize = Size((br.x - tl.x).coerceAtLeast(1f), (br.y - tl.y).coerceAtLeast(1f))
                drawRect(color = color.copy(alpha = 0.125f), topLeft = tl, size = boxSize)
                drawRect(color = color.copy(alpha = if (isSel) 0.9f else 0.5f), topLeft = tl, size = boxSize, style = Stroke(width = if (isSel) 3f else 2f))
            }
        }
    }
}
