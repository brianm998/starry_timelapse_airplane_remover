package com.star.desktop.ui.sequence.grid

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ContextMenuArea
import androidx.compose.foundation.ContextMenuItem
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerKeyboardModifiers
import androidx.compose.ui.input.pointer.isCtrlPressed
import androidx.compose.ui.input.pointer.isMetaPressed
import androidx.compose.ui.input.pointer.isShiftPressed
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameState
import com.star.desktop.domain.InteractionMode
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.FrameInfo
import com.star.proto.FrameProcessingState
import com.star.proto.FrameViewMode
import com.star.proto.GetHorizonOverlayResponse
import com.star.proto.HorizonOverlayKind
import com.star.proto.ReprocessingType

/** Grid mode (macOS `GridView`): Lightroom-style thumbnail grid with per-cell status, sized by the scale slider. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun GridView(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val states by vm.frameStates.collectAsState()
    val current by vm.currentIndex.collectAsState()
    val selected by vm.selected.collectAsState()
    val viewMode by vm.viewMode.collectAsState()
    val scale by vm.gridThumbnailScale.collectAsState()
    val showHorizon by vm.showHorizonOnGrid.collectAsState()

    val cellWidth = (vm.info.imageWidth * scale).coerceIn(70f, 1000f)
    val gridState = rememberLazyGridState()
    LaunchedEffect(Unit) { gridState.scrollToItem(current.coerceAtLeast(0)) }
    LaunchedEffect(current) { gridState.animateScrollToItem(current.coerceAtLeast(0)) }

    LazyVerticalGrid(
        state = gridState,
        columns = GridCells.Adaptive(minSize = cellWidth.dp),
        modifier = modifier.fillMaxSize().background(StarColors.appBackground),
        contentPadding = PaddingValues(8.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        items((0 until vm.frameCount).toList(), key = { it }) { i ->
            GridCell(
                vm = vm,
                index = i,
                isCurrent = i == current,
                isInSelection = i != current && i in selected,
                state = states[i],
                viewMode = viewMode,
                showHorizon = showHorizon,
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class)
@Composable
private fun GridCell(
    vm: SequenceViewModel,
    index: Int,
    isCurrent: Boolean,
    isInSelection: Boolean,
    state: FrameProcessingState?,
    viewMode: FrameViewMode,
    showHorizon: Boolean,
) {
    var thumb by remember(index) { mutableStateOf<ImageBitmap?>(null) }
    var info by remember(index) { mutableStateOf<FrameInfo?>(null) }
    var overlay by remember(index) { mutableStateOf<GetHorizonOverlayResponse?>(null) }
    LaunchedEffect(index, viewMode, state) { thumb = vm.loadThumb(index, viewMode) }
    LaunchedEffect(index, state) { info = vm.frameInfo(index) }
    LaunchedEffect(index, showHorizon, state) {
        overlay = if (showHorizon) {
            val h = (256f * vm.info.imageHeight / vm.info.imageWidth.coerceAtLeast(1)).toInt().coerceAtLeast(1)
            vm.gridHorizonOverlay(index, 256, h)
        } else null
    }
    var mods by remember { mutableStateOf<PointerKeyboardModifiers?>(null) }

    val reprocessItems = {
        listOf(
            ContextMenuItem("Process (new only)") { vm.reprocessSelected(ReprocessingType.REPROCESS_NONE) },
            ContextMenuItem("Re-Process Alignment") { vm.reprocessSelected(ReprocessingType.REPROCESS_ALIGNMENT) },
            ContextMenuItem("Re-Process Outliers") { vm.reprocessSelected(ReprocessingType.REPROCESS_OUTLIERS) },
            ContextMenuItem("Re-Process Horizons") { vm.reprocessSelected(ReprocessingType.REPROCESS_HORIZONS) },
            ContextMenuItem("Re-Process Everything") { vm.reprocessSelected(ReprocessingType.REPROCESS_EVERYTHING) },
        )
    }

    val bg = when {
        isCurrent -> StarColors.cellHighlighted
        isInSelection -> StarColors.cellSelected
        else -> StarColors.cellDefault
    }
    val borderMod = when {
        isCurrent -> Modifier.border(2.dp, SolidColor(StarColors.accent), StarShapes.gridCell)
        isInSelection -> Modifier.border(1.dp, SolidColor(StarColors.accent.copy(alpha = 0.55f)), StarShapes.gridCell)
        else -> Modifier
    }
    val aspect = if (vm.info.imageHeight > 0) vm.info.imageWidth.toFloat() / vm.info.imageHeight else 1.5f

    ContextMenuArea(items = reprocessItems) {
      Column(
        Modifier
            .clip(StarShapes.gridCell)
            .background(bg)
            .then(borderMod)
            .onPointerEvent(PointerEventType.Press) { mods = it.keyboardModifiers }
            .combinedClickable(
                onClick = {
                    val m = mods
                    when {
                        m?.isShiftPressed == true -> vm.select(index, range = true)
                        m?.isCtrlPressed == true || m?.isMetaPressed == true -> vm.select(index, additive = true)
                        else -> vm.select(index)
                    }
                },
                onDoubleClick = { vm.setCurrentIndex(index); vm.select(index); vm.setMode(InteractionMode.EDIT) },
            )
            .padding(4.dp),
    ) {
        // Header: 0-based frame number · outlier dots · clean-method icon.
        Row(Modifier.fillMaxWidth().padding(bottom = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("$index", color = StarColors.white, fontSize = 11.sp)
            Box(Modifier.weight(1f))
            val fi = info
            if (fi != null) {
                Row(horizontalArrangement = Arrangement.spacedBy((-4).dp), verticalAlignment = Alignment.CenterVertically) {
                    if (fi.numPositiveOutliers != 0) OutlierDot(StarColors.red)
                    if (fi.numUndecidedOutliers != 0) OutlierDot(StarColors.orange)
                    if (fi.numNegativeOutliers != 0) OutlierDot(StarColors.green)
                }
                Box(Modifier.padding(start = 3.dp)) { CleanMethodIcon(fi.cleanMethod, StarColors.white, 9.dp) }
            }
        }

        Box(Modifier.fillMaxWidth().aspectRatio(aspect).clip(StarShapes.gridCell), contentAlignment = Alignment.BottomStart) {
            val t = thumb
            if (t != null) {
                Image(bitmap = t, contentDescription = "Frame $index", modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
            // Per-cell horizon overlay (kind → color), scaled from the overlay's draw space.
            val ov = overlay
            if (ov != null && ov.exists && ov.yPerColumnList.isNotEmpty()) {
                val lineColor = when (ov.kind) {
                    HorizonOverlayKind.HORIZON_OVERLAY_KIND_REFERENCE -> StarColors.green
                    HorizonOverlayKind.HORIZON_OVERLAY_KIND_MERGED -> StarColors.blue
                    else -> StarColors.white
                }
                Canvas(Modifier.fillMaxSize()) {
                    val ys = ov.yPerColumnList
                    val sx = size.width / ys.size
                    val sy = if (ov.height > 0) size.height / ov.height else 1f
                    val path = Path()
                    ys.forEachIndexed { i, y ->
                        val px = i * sx
                        val py = y * sy
                        if (i == 0) path.moveTo(px, py) else path.lineTo(px, py)
                    }
                    drawPath(path, color = lineColor, style = Stroke(width = 1.5.dp.toPx()))
                }
            }
            if (state != null) {
                val s = FrameState.shortString(state)
                if (s.isNotEmpty()) {
                    Text(s, color = StarColors.green, fontSize = 10.sp, modifier = Modifier.padding(start = 4.dp, bottom = 2.dp))
                }
            }
        }
      }
    }
}

/** A small diagonal stroke standing in for the macOS `line.diagonal` outlier indicator. */
@Composable
private fun OutlierDot(color: Color) {
    Text("╱", color = color, fontSize = 9.sp)
}
