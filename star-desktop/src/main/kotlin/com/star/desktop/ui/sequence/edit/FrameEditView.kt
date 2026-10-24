package com.star.desktop.ui.sequence.edit

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.ClickRules
import com.star.desktop.domain.StreakLine
import com.star.desktop.i18n.localized
import kotlinx.coroutines.delay
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
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.isPrimaryPressed
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.input.pointer.pointerHoverIcon
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.toSize
import com.star.desktop.ui.components.drawHorizonLines
import com.star.desktop.domain.usesOutliers
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import androidx.compose.ui.draw.clipToBounds
import kotlin.math.abs
import kotlin.math.roundToInt

/** How many columns the horizon line is fetched at: enough for a smooth line at any realistic zoom on one screen. */
private const val HORIZON_COLUMNS = 1024

/** How long loading a frame's outliers goes on before the indicator appears, so the reload after each edit does not flash it. */
private const val LOADING_INDICATOR_DELAY_MILLIS = 250L

/**
 * Edit-mode center view (macOS `FrameEditView` + `OutlierGroupView`): the frame image with
 * zoom and pan ([zoomAndPan]), double-click between fit and actual size, the outlier overlay, and click
 * hit-testing — all driven by the session's one [FrameTransform] so they stay aligned at every zoom/pan, and
 * so the zoom does not reset when the frame changes.
 *
 * Pinch (macOS `ZoomableModifier`'s `MagnificationGesture`): Compose Desktop has no multi-touch
 * trackpad gesture API (it targets mouse + single-pointer input), so there is no dedicated pinch
 * handler here; a trackpad's two-finger scroll pans, and Ctrl/Cmd with it zooms.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun FrameEditView(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val current by vm.currentIndex.collectAsState()
    val fvm = remember(current) { vm.frameVMFor(current) }
    LaunchedEffect(current) { fvm.load() }

    val preview by vm.currentPreview.collectAsState()
    // Zoomed in with "show full resolution" on, the full-size image stands in for the preview (macOS FrameEditImageView).
    val fullResolution by vm.fullResolution.collectAsState()
    val bmp = fullResolution ?: preview
    val selectedTool by vm.tool.collectAsState()
    val frameInfo by fvm.info.collectAsState()
    // The tools do nothing on a frame whose clean method doesn't review outliers, and there is nothing to draw for them either.
    val usesOutliers = (frameInfo?.cleanMethod ?: com.star.proto.CleanMethod.CLEAN_SELECTIVE).usesOutliers
    val tool = if (!usesOutliers) com.star.desktop.domain.ToolType.NONE else selectedTool
    val groups by fvm.groups.collectAsState()
    val decisions by fvm.decisions.collectAsState()
    val selection by fvm.selection.collectAsState()
    val hovered by fvm.hovered.collectAsState()
    val labelMap by fvm.labelMap.collectAsState()
    val outlierOpacity by vm.outlierOpacity.collectAsState()
    val frameOpacity by vm.frameOpacity.collectAsState()
    val multiChoiceMode by vm.multiChoiceMode.collectAsState()
    // The area the multi tool was dragged over stays on screen while its sheet is up.
    val pendingSelection by vm.multiSelect.collectAsState()
    val loadingOutliers by fvm.loading.collectAsState()
    val textMeasurer = rememberTextMeasurer()
    val noLineText = localized("ui.no_line")
    val noLineLayout = remember(noLineText, textMeasurer) {
        textMeasurer.measure(noLineText, TextStyle(color = StarColors.red, fontSize = 13.sp))
    }
    val viewConfiguration = LocalViewConfiguration.current

    var showLoading by remember(current) { mutableStateOf(false) }
    LaunchedEffect(current, loadingOutliers, usesOutliers) {
        if (loadingOutliers && usesOutliers) { delay(LOADING_INDICATOR_DELAY_MILLIS); showLoading = true } else showLoading = false
    }

    val transform = vm.transform
    // The outlier groups as tinted pixels (macOS draws each group's own pixels, not a box around it), rebuilt off the UI
    // thread when a decision, the selection or the frame's groups change.
    var outlierOverlay by remember(current) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(current, labelMap, groups, decisions, selection, usesOutliers) {
        val map = labelMap
        outlierOverlay = if (usesOutliers && map != null && groups.isNotEmpty()) {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
                OutlierOverlay.pixels(map, groups, decisions, selection).toImageBitmap()
            }
        } else null
    }
    // The trash, as a yellow mask under the groups, while it is shown (macOS computes its image when the toggle goes on).
    val showTrash by vm.showTrash.collectAsState()
    val trashOpacity by vm.trashOpacity.collectAsState()
    var trashBitmap by remember(current) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(current, showTrash, usesOutliers, groups, trashOpacity) {
        trashBitmap = if (showTrash && usesOutliers) {
            fvm.loadTrashMask()?.let { mask ->
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) { TrashOverlay.bitmap(mask, trashOpacity) }
            }
        } else null
    }
    // The horizon line (macOS `showHorizonOnMainView`): fetched for this frame when it is shown, and again whenever the horizon
    // or the frame's being pending refinement may have changed (a reference saved, a refinement operation finished).
    val showHorizon by vm.showHorizonOnMainView.collectAsState()
    val visibleHorizonKinds by vm.visibleHorizonLineKinds.collectAsState()
    val horizonVersion by vm.horizonVersion.collectAsState()
    val frameStates by vm.frameStates.collectAsState()
    var horizonOverlay by remember(current) { mutableStateOf<com.star.proto.GetHorizonOverlayResponse?>(null) }
    LaunchedEffect(current, showHorizon, horizonVersion, frameStates[current]) {
        horizonOverlay = if (showHorizon) {
            val w = HORIZON_COLUMNS
            vm.horizonOverlay(current, w, (w.toFloat() * vm.info.imageHeight / vm.info.imageWidth.coerceAtLeast(1)).toInt().coerceAtLeast(1))
        } else null
    }
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
            .clipToBounds()
            .pointerHoverIcon(cursorIcon, overrideDescendants = true)
            .onSizeChanged { canvasSize = it.toSize(); transform.canvasChanged(canvasSize) }
            .zoomAndPan(transform) { canvasSize }
            .pointerInput(tool, canvasSize) {
                // The finally clears transient drag state if this gesture is cancelled because `tool`/`canvasSize`
                // changed mid-drag (Compose disposes the pointerInput then; onDragEnd/Cancel may not run), so the
                // pointing cursor and rubber-band rectangle can't get stuck.
                try {
                    if (tool.isAreaDrag) {
                        // Area tools: drag a rubber-band rectangle, then either open the multi-select sheet
                        // (MULTI) or apply the editing tool directly to the rectangle (razor/shovel/trash/extract).
                        detectDragGestures(
                            onDragStart = { pos -> dragging = true; selStartImg = transform.canvasToImage(pos, canvasSize); selEndImg = selStartImg },
                            onDragEnd = {
                                val s = selStartImg; val e = selEndImg
                                if (s != null && e != null) {
                                    when (tool) {
                                        com.star.desktop.domain.ToolType.MULTI ->
                                            vm.openMultiSelect(SequenceViewModel.RectSelection(s.x, s.y, e.x, e.y))
                                        // Remove / Keep set every group wholly inside the box; Information lists them.
                                        com.star.desktop.domain.ToolType.REMOVE -> fvm.setDecisionsInBox(true, s.x, s.y, e.x, e.y, includingTrash = showTrash)
                                        com.star.desktop.domain.ToolType.KEEP -> fvm.setDecisionsInBox(false, s.x, s.y, e.x, e.y, includingTrash = showTrash)
                                        com.star.desktop.domain.ToolType.INFORMATION ->
                                            vm.showInfoFor(fvm.groupsInBox(s.x, s.y, e.x, e.y).map { it.id })
                                        else -> fvm.applyAreaTool(tool, s.x, s.y, e.x, e.y, includingTrash = showTrash)
                                    }
                                }
                                selStartImg = null; selEndImg = null; dragging = false
                            },
                            onDragCancel = { selStartImg = null; selEndImg = null; dragging = false },
                        ) { change, _ -> selEndImg = transform.canvasToImage(change.position, canvasSize); change.consume() }
                    } else {
                        detectDragGestures(
                            onDragStart = { dragging = true },
                            onDragEnd = { dragging = false },
                            onDragCancel = { dragging = false },
                        ) { change, drag -> transform.panBy(drag, canvasSize); change.consume() }
                    }
                } finally {
                    dragging = false; selStartImg = null; selEndImg = null
                }
            }
            .pointerInput(tool, labelMap, groups, usesOutliers, multiChoiceMode) {
                // A click on a group acts at once (macOS puts the tap on the group's own view); only a click on nothing can start
                // a double-click, which toggles fit and actual size (macOS `ZoomableModifier.doubleTapGesture`), keeping the
                // clicked point still. Waiting out a possible second click on a group made every click on one lag.
                var lastEmptyClick: ClickRules.EmptyClick? = null
                awaitEachGesture {
                    awaitFirstDown()
                    if (!currentEvent.buttons.isPrimaryPressed) return@awaitEachGesture
                    val up = waitForUpOrCancellation() ?: return@awaitEachGesture
                    val pos = up.position
                    val img = transform.canvasToImage(pos, canvasSize)
                    val gid = if (usesOutliers) fvm.hitAt(img.x, img.y, vm.info.imageWidth.toFloat(), vm.info.imageHeight.toFloat()) else 0
                    if (gid > 0) {
                        lastEmptyClick = null
                        val decided = com.star.desktop.domain.OutlierDecisions.willRemove(fvm.decisionFor(gid)) != null
                        when (ClickRules.groupClick(tool, multiChoiceMode, decided)) {
                            ClickRules.GroupClick.OPEN_MULTI_CHOICE -> {
                                val willRemove = com.star.desktop.domain.OutlierDecisions.willRemove(fvm.decisionFor(gid)) == true
                                vm.openMultiChoice(current, gid, willRemove)
                            }
                            // An Information click lists that group alone in the outlier window, selected (macOS handleDetailsMode).
                            ClickRules.GroupClick.APPLY_TOOL ->
                                if (tool == com.star.desktop.domain.ToolType.INFORMATION) vm.showInfoFor(listOf(gid), select = true) else fvm.applyTool(gid, tool)
                        }
                    } else if (ClickRules.completesDoubleClick(
                            lastEmptyClick, up.uptimeMillis, pos.x, pos.y,
                            viewConfiguration.doubleTapTimeoutMillis, viewConfiguration.touchSlop,
                        )
                    ) {
                        lastEmptyClick = null
                        transform.toggleFitActual(pos, canvasSize)
                    } else {
                        lastEmptyClick = ClickRules.EmptyClick(up.uptimeMillis, pos.x, pos.y)
                    }
                }
            }
            // Hover tracking drives arrow/line color + visibility (macOS `arrowSelected`).
            .onPointerEvent(PointerEventType.Move) { ev ->
                val pos = ev.changes.firstOrNull()?.position ?: return@onPointerEvent
                val img = transform.canvasToImage(pos, canvasSize)
                val gid = fvm.hitAt(img.x, img.y, vm.info.imageWidth.toFloat(), vm.info.imageHeight.toFloat())
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
                // The frame opacity slider dims the image with black (macOS draws a black rectangle at 1 - opacity over it, under the
                // outliers); it belongs to the outlier tools, so a frame that has none is not dimmed.
                if (usesOutliers && frameOpacity < 1f) {
                    drawRect(
                        color = Color.Black.copy(alpha = 1f - frameOpacity),
                        topLeft = Offset(o.x, o.y),
                        size = Size(vm.info.imageWidth * s, vm.info.imageHeight * s),
                    )
                }
            }
            // The horizon line, through the frame transform so it stays on the image at every zoom and pan; a constant
            // screen thickness (macOS divides by the zoom for the same effect).
            horizonOverlay?.let { ov ->
                drawHorizonLines(
                    ov, visibleHorizonKinds, vm.info.imageWidth.toFloat(), vm.info.imageHeight.toFloat(), strokeWidth = 3f,
                ) { transform.imageToCanvas(it, size) }
            }
            // Everything the outlier tools draw is one layer, so the outlier opacity slider fades it as a whole (macOS applies
            // `outlierOpacity` to the ZStack of trash, groups, boxes and arrows).
            fun outlierLayer() {
                // Outlier overlay (macOS OutlierGroupView): box fill+stroke (groupColor), plus inward
                // direction arrows + guide lines (arrowColor) gated on hover/decision/selection.
                val fw = vm.info.imageWidth.toFloat()
                val fh = vm.info.imageHeight.toFloat()
                val al = fw / SequenceViewModel.ARROW_LENGTH_DIVISOR // arrow length (long/pointing axis)
                val ah = fw / SequenceViewModel.ARROW_HEIGHT_DIVISOR // arrow height (cross axis)
                val lw = (fw / 1440f * s).coerceAtLeast(1f)         // guide-line thickness
                // Trash goes below the groups.
                trashBitmap?.let { tb ->
                    drawImage(
                        image = tb,
                        dstOffset = IntOffset(o.x.roundToInt(), o.y.roundToInt()),
                        dstSize = IntSize((fw * s).roundToInt(), (fh * s).roundToInt()),
                    )
                }
                // The groups' own pixels, tinted by decision; small ones in the combined masks.
                outlierOverlay?.let { ov ->
                    drawImage(
                        image = ov,
                        dstOffset = IntOffset(o.x.roundToInt(), o.y.roundToInt()),
                        dstSize = IntSize((fw * s).roundToInt(), (fh * s).roundToInt()),
                    )
                }
                // Only what is a separate thing in the UI gets a box, guide lines and arrows; and the box only while hovered or selected.
                for (g in if (usesOutliers) groups.filter(OutlierOverlay::isLarge) else emptyList()) {
                    val reason = decisions[g.id] ?: g.shouldRemove
                    val isSel = g.id in selection
                    val isHover = hovered == g.id
                    val active = isSel || isHover
                    val willRemove = com.star.desktop.domain.OutlierDecisions.willRemove(reason)
                    val box = StarColors.groupColor(reason, isSel)
                    val arrow = StarColors.arrowColor(reason, isSel, isHover)

                    val tl = transform.imageToCanvas(Offset(g.bounds.minX.toFloat(), g.bounds.minY.toFloat()), size)
                    val br = transform.imageToCanvas(Offset(g.bounds.maxX.toFloat(), g.bounds.maxY.toFloat()), size)
                    val boxSize = Size((br.x - tl.x).coerceAtLeast(1f), (br.y - tl.y).coerceAtLeast(1f))
                    if (active) {
                        drawRect(color = box.copy(alpha = 0.125f), topLeft = tl, size = boxSize)
                        drawRect(color = box.copy(alpha = 0.9f), topLeft = tl, size = boxSize, style = Stroke(width = 4f))
                        // The streak line the daemon fitted through the group, faint white (macOS: α0.33, 8 image pixels wide, so it
                        // grows with the zoom); or "No Line" in the box when there is none. A group arrives with its line already
                        // worked out, so there is no "calculating" state to show here.
                        val streak = StreakLine.segment(g)
                        if (streak != null) {
                            drawLine(
                                color = Color.White.copy(alpha = 0.33f),
                                start = transform.imageToCanvas(Offset(streak.x1, streak.y1), size),
                                end = transform.imageToCanvas(Offset(streak.x2, streak.y2), size),
                                strokeWidth = (8f * s).coerceAtLeast(2f),
                            )
                        } else if (!g.hasLine()) {
                            drawText(
                                noLineLayout,
                                topLeft = Offset(
                                    tl.x + (boxSize.width - noLineLayout.size.width) / 2f,
                                    tl.y + (boxSize.height - noLineLayout.size.height) / 2f,
                                ),
                            )
                        }
                    }

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
            }
            if (outlierOpacity < 1f) {
                val layer = Paint().apply { alpha = outlierOpacity }
                drawContext.canvas.saveLayer(Rect(Offset.Zero, size), layer)
                outlierLayer()
                drawContext.canvas.restore()
            } else {
                outlierLayer()
            }

            // The box being dragged for an area tool, in the tool's own colour (macOS `selectionColor`); and, while the multi
            // tool's sheet is up, the box it was dragged over.
            fun selectionBox(a: Offset, b: Offset, color: Color) {
                val p1 = transform.imageToCanvas(a, size)
                val p2 = transform.imageToCanvas(b, size)
                val rtl = Offset(minOf(p1.x, p2.x), minOf(p1.y, p2.y))
                val rsz = Size(abs(p2.x - p1.x), abs(p2.y - p1.y))
                drawRect(color = color.copy(alpha = 0.2f), topLeft = rtl, size = rsz)
                drawRect(color = color.copy(alpha = 0.8f), topLeft = rtl, size = rsz, style = Stroke(width = 2f))
            }
            val ss = selStartImg
            val se = selEndImg
            val pending = pendingSelection
            if (ss != null && se != null) {
                selectionBox(ss, se, StarColors.toolColor(tool))
            } else if (pending != null) {
                selectionBox(Offset(pending.startX, pending.startY), Offset(pending.endX, pending.endY), StarColors.toolColor(com.star.desktop.domain.ToolType.MULTI))
            }
        }
        // Loading the frame's outliers (macOS ProgressBars): a bar along the bottom, a little faded.
        if (showLoading) {
            Row(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(12.dp).alpha(0.6f),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(localized("ui.loading_outliers_for_this_frame"), color = StarColors.white, fontSize = 12.sp)
                LinearProgressIndicator(Modifier.weight(1f), color = StarColors.white, trackColor = StarColors.cellDefault)
            }
        }
    }
}
