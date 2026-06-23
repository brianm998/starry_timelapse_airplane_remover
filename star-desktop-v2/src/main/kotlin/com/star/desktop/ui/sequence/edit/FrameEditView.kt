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
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.input.pointer.pointerHoverIcon
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.toSize
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import kotlin.math.abs
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
    val hovered by fvm.hovered.collectAsState()
    val labelMap by fvm.labelMap.collectAsState()

    val transform = remember(current) { FrameTransform(vm.info.imageWidth, vm.info.imageHeight) }
    var canvasSize by remember { mutableStateOf(Size.Zero) }
    var dragging by remember { mutableStateOf(false) }
    // Rubber-band selection (image coords) while the multi tool drags.
    var selStartImg by remember { mutableStateOf<Offset?>(null) }
    var selEndImg by remember { mutableStateOf<Offset?>(null) }

    // Tool-dependent cursor: pointing while dragging or hovering a group, else the tool crosshair.
    val cursorIcon = when {
        tool == com.star.desktop.domain.ToolType.NONE -> androidx.compose.ui.input.pointer.PointerIcon.Default
        dragging -> ToolCursors.pointing(tool)
        hovered != null -> ToolCursors.groupPointing(tool, com.star.desktop.domain.OutlierDecisions.willRemove(decisions[hovered] ?: com.star.proto.RemoveReason.RR_UNDECIDED))
        else -> ToolCursors.crosshair(tool)
    }

    Box(
        modifier
            .fillMaxSize()
            .background(StarColors.appBackground)
            .pointerHoverIcon(cursorIcon, overrideDescendants = true)
            .onSizeChanged { canvasSize = it.toSize() }
            .onPointerEvent(PointerEventType.Scroll) { ev ->
                val change = ev.changes.firstOrNull() ?: return@onPointerEvent
                val dy = change.scrollDelta.y
                if (dy != 0f) {
                    transform.zoomBy(if (dy < 0) 1.1f else 1f / 1.1f, change.position, canvasSize)
                    change.consume()
                }
            }
            .pointerInput(tool, canvasSize) {
                if (tool == com.star.desktop.domain.ToolType.MULTI) {
                    // Multi tool: drag a rubber-band rectangle, then open the multi-select sheet.
                    detectDragGestures(
                        onDragStart = { pos -> selStartImg = transform.canvasToImage(pos, canvasSize); selEndImg = selStartImg },
                        onDragEnd = {
                            val s = selStartImg; val e = selEndImg
                            if (s != null && e != null) vm.openMultiSelect(SequenceViewModel.RectSelection(s.x, s.y, e.x, e.y))
                            selStartImg = null; selEndImg = null
                        },
                        onDragCancel = { selStartImg = null; selEndImg = null },
                    ) { change, _ -> selEndImg = transform.canvasToImage(change.position, canvasSize); change.consume() }
                } else {
                    detectDragGestures(
                        onDragStart = { dragging = true },
                        onDragEnd = { dragging = false },
                        onDragCancel = { dragging = false },
                    ) { change, drag -> transform.panBy(drag); change.consume() }
                }
            }
            .pointerInput(tool, labelMap, groups) {
                detectTapGestures { pos ->
                    val map = labelMap ?: return@detectTapGestures
                    val img = transform.canvasToImage(pos, canvasSize)
                    val gid = map.idAt(img.x.roundToInt(), img.y.roundToInt())
                    if (gid > 0) {
                        if (tool == com.star.desktop.domain.ToolType.MULTI) {
                            val willRemove = com.star.desktop.domain.OutlierDecisions.willRemove(fvm.decisionFor(gid)) == true
                            vm.openMultiChoice(current, gid, willRemove)
                        } else {
                            fvm.applyTool(gid, tool)
                        }
                    }
                }
            }
            // Hover tracking drives arrow/line color + visibility (macOS `arrowSelected`).
            .onPointerEvent(PointerEventType.Move) { ev ->
                val pos = ev.changes.firstOrNull()?.position ?: return@onPointerEvent
                val map = labelMap
                val gid = if (map != null) {
                    val img = transform.canvasToImage(pos, canvasSize)
                    map.idAt(img.x.roundToInt(), img.y.roundToInt())
                } else 0
                fvm.hover(if (gid > 0) gid else null)
            }
            .onPointerEvent(PointerEventType.Exit) { fvm.hover(null) },
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
            // Outlier overlay (macOS OutlierGroupView): box fill+stroke (groupColor), plus inward
            // direction arrows + guide lines (arrowColor) gated on hover/decision/selection.
            val fw = vm.info.imageWidth.toFloat()
            val fh = vm.info.imageHeight.toFloat()
            val al = fw / 70f                                   // arrow length (long/pointing axis)
            val ah = fw / 180f                                  // arrow height (cross axis)
            val lw = (fw / 1440f * s).coerceAtLeast(1f)         // guide-line thickness
            for (g in groups) {
                val reason = decisions[g.id] ?: g.shouldRemove
                val isSel = selected == g.id
                val isHover = hovered == g.id
                val active = isSel || isHover
                val willRemove = com.star.desktop.domain.OutlierDecisions.willRemove(reason)
                val box = StarColors.groupColor(reason, isSel)
                val arrow = StarColors.arrowColor(reason, isSel, isHover)

                val tl = transform.imageToCanvas(Offset(g.bounds.minX.toFloat(), g.bounds.minY.toFloat()), size)
                val br = transform.imageToCanvas(Offset(g.bounds.maxX.toFloat(), g.bounds.maxY.toFloat()), size)
                val boxSize = Size((br.x - tl.x).coerceAtLeast(1f), (br.y - tl.y).coerceAtLeast(1f))
                drawRect(color = box.copy(alpha = 0.125f), topLeft = tl, size = boxSize)
                drawRect(color = box.copy(alpha = if (active) 0.9f else 0.5f), topLeft = tl, size = boxSize, style = Stroke(width = if (active) 4f else 2f))

                val cx = g.bounds.minX + (g.bounds.maxX - g.bounds.minX + 1) / 2f
                val cy = g.bounds.minY + (g.bounds.maxY - g.bounds.minY + 1) / 2f

                // Guide lines: edge → box on all four sides (only when hovered or selected).
                if (active) {
                    fun line(x1: Float, y1: Float, x2: Float, y2: Float) {
                        drawLine(
                            color = arrow.copy(alpha = 0.5f),
                            start = transform.imageToCanvas(Offset(x1, y1), size),
                            end = transform.imageToCanvas(Offset(x2, y2), size),
                            strokeWidth = lw,
                        )
                    }
                    line(0f, cy, g.bounds.minX.toFloat(), cy)                    // left
                    line(cx, 0f, cx, g.bounds.minY.toFloat())                    // top
                    line((g.bounds.maxX + 1).toFloat(), cy, fw, cy)             // right
                    line(cx, (g.bounds.maxY + 1).toFloat(), cx, fh)            // bottom
                }

                // Inward arrows: shown when hovered, undecided, will-remove, or selected.
                if (isHover || willRemove == true || willRemove == null || isSel) {
                    fun tri(ax: Float, ay: Float, b1x: Float, b1y: Float, b2x: Float, b2y: Float) {
                        val a = transform.imageToCanvas(Offset(ax, ay), size)
                        val b1 = transform.imageToCanvas(Offset(b1x, b1y), size)
                        val b2 = transform.imageToCanvas(Offset(b2x, b2y), size)
                        drawPath(Path().apply { moveTo(a.x, a.y); lineTo(b1.x, b1.y); lineTo(b2.x, b2.y); close() }, color = arrow)
                    }
                    tri(0f, cy, -al, cy - ah / 2f, -al, cy + ah / 2f)             // left (points right)
                    tri(cx, 0f, cx - ah / 2f, -al, cx + ah / 2f, -al)             // top (points down)
                    tri(fw, cy, fw + al, cy - ah / 2f, fw + al, cy + ah / 2f)     // right (points left)
                    tri(cx, fh, cx - ah / 2f, fh + al, cx + ah / 2f, fh + al)     // bottom (points up)
                }
            }

            // Rubber-band selection rectangle (multi tool drag).
            val ss = selStartImg
            val se = selEndImg
            if (ss != null && se != null) {
                val p1 = transform.imageToCanvas(ss, size)
                val p2 = transform.imageToCanvas(se, size)
                val rtl = Offset(minOf(p1.x, p2.x), minOf(p1.y, p2.y))
                val rsz = Size(abs(p2.x - p1.x), abs(p2.y - p1.y))
                drawRect(color = StarColors.accent.copy(alpha = 0.2f), topLeft = rtl, size = rsz)
                drawRect(color = StarColors.accent, topLeft = rtl, size = rsz, style = Stroke(width = 1.5f))
            }
        }
    }
}
