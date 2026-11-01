package com.star.desktop.ui.sequence.grid

import com.star.desktop.i18n.localized
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameState
import com.star.desktop.domain.InteractionMode
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.components.drawHorizonLines
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.FrameInfo
import com.star.proto.FrameProcessingState
import com.star.proto.FrameViewMode
import com.star.proto.GetHorizonOverlayResponse
import com.star.proto.HorizonOverlayKind
import com.star.proto.ReprocessingType
import com.star.desktop.ui.sequence.frameCellClicks
import com.star.desktop.ui.sequence.frameCellMenu

/** Grid mode (macOS `GridView`): Lightroom-style thumbnail grid with per-cell status, sized by the scale slider. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun GridView(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val states by vm.frameStates.collectAsState()
    val current by vm.currentIndex.collectAsState()
    val selected by vm.selected.collectAsState()
    val viewMode by vm.viewMode.collectAsState()
    val scale by vm.gridThumbnailScale.collectAsState()
    val showHorizon by vm.showHorizonOnMainView.collectAsState()
    val horizonVersion by vm.horizonVersion.collectAsState()
    val revisions by vm.frameRevisions.collectAsState()
    val dataVersions by vm.frameDataVersions.collectAsState()

    val cellWidth = (vm.info.imageWidth * scale).coerceIn(70f, 1000f)
    val gridState = rememberLazyGridState()
    // The current frame goes to the middle of the view, not the top edge (macOS scrolls to its anchor).
    LaunchedEffect(Unit) { gridState.centerOn(current.coerceAtLeast(0), animate = false) }
    LaunchedEffect(current) { gridState.centerOn(current.coerceAtLeast(0), animate = true) }

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
                selectedCount = selected.size,
                state = states[i],
                viewMode = viewMode,
                showHorizon = showHorizon,
                revision = revisions[i] ?: 0,
                dataVersion = dataVersions[i] ?: 0,
                horizonVersion = horizonVersion,
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
    selectedCount: Int,
    state: FrameProcessingState?,
    viewMode: FrameViewMode,
    showHorizon: Boolean,
    /** Changes when a picture of this frame is saved, so the thumbnail is fetched again. */
    revision: Int,
    /** Changes when what the client holds of this frame is out of date, so its counts are fetched again. */
    dataVersion: Int,
    /** Changes when a horizon (or a frame's being pending refinement) may have changed, so the line is fetched again. */
    horizonVersion: Int,
) {
    var thumb by remember(index) { mutableStateOf<ImageBitmap?>(null) }
    // True once the daemon has been asked for this mode's picture and has none: the cell says so rather than showing another mode (Q1).
    var missing by remember(index, viewMode) { mutableStateOf(false) }
    // The frame's counts as the view model has them, which an edit made anywhere changes (Q11); fetched when the frame's data goes stale.
    val info by vm.frameInfoFlow(index).collectAsState()
    var overlay by remember(index) { mutableStateOf<GetHorizonOverlayResponse?>(null) }
    val visibleHorizonKinds by vm.visibleHorizonLineKinds.collectAsState()
    LaunchedEffect(index, viewMode, state, revision) {
        thumb = vm.loadThumb(index, viewMode)
        missing = thumb == null
    }
    LaunchedEffect(index, state, dataVersion, horizonVersion) { vm.refreshFrameInfo(index) }
    LaunchedEffect(index, showHorizon, state, horizonVersion) {
        overlay = if (showHorizon) {
            val h = (256f * vm.info.imageHeight / vm.info.imageWidth.coerceAtLeast(1)).toInt().coerceAtLeast(1)
            vm.horizonOverlay(index, 256, h)
        } else null
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

    // A menu about the selection, only on a cell that is in it, with how many frames it acts on.
    ContextMenuArea(items = { frameCellMenu(vm, isCurrent || isInSelection, selectedCount) }) {
      Column(
        Modifier
            .clip(StarShapes.gridCell)
            .background(bg)
            .then(borderMod)
            .testTag("grid.cell.${index}")
            .frameCellClicks(vm, index, onDoubleClick = { vm.setCurrentIndex(index); vm.select(index); vm.setMode(InteractionMode.EDIT) })
            .padding(4.dp),
    ) {
        // Header: 0-based frame number · outlier dots · clean-method icon.
        Row(Modifier.fillMaxWidth().padding(bottom = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("$index", color = StarColors.white, fontSize = 11.sp)
            Box(Modifier.weight(1f))
            val fi = info
            if (fi != null) {
                // Only once the outliers are loaded: before that the counts are zeroes that mean nothing.
                if (fi.outliersLoaded) {
                    Row(horizontalArrangement = Arrangement.spacedBy((-4).dp), verticalAlignment = Alignment.CenterVertically) {
                        if (fi.numPositiveOutliers != 0) OutlierDot(StarColors.red)
                        if (fi.numUndecidedOutliers != 0) OutlierDot(StarColors.orange)
                        if (fi.numNegativeOutliers != 0) OutlierDot(StarColors.green)
                    }
                }
                Box(Modifier.padding(start = 3.dp)) { CleanMethodIcon(fi.cleanMethod, StarColors.white, 9.dp) }
            }
        }

        Box(Modifier.fillMaxWidth().aspectRatio(aspect).clip(StarShapes.gridCell), contentAlignment = Alignment.BottomStart) {
            val t = thumb
            if (t != null) {
                Image(bitmap = t, contentDescription = localized("ui.frame_n", index), modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            } else if (missing) {
                com.star.desktop.ui.sequence.ImageNotFound(com.star.desktop.ui.sequence.imageNotFoundText(viewMode), fontSize = 10.sp, modifier = Modifier.fillMaxSize())
            }
            // Per-cell horizon lines of the kinds switched on (the composite's orange while pending), scaled from the overlay's draw space.
            val ov = overlay
            if (ov != null && ov.exists) {
                Canvas(Modifier.fillMaxSize()) {
                    drawHorizonLines(ov, visibleHorizonKinds, size.width, size.height, 1.5.dp.toPx()) { it }
                }
            }
            // What the frame is doing, in the state's own colour, and nothing on a finished one (macOS: a complete frame has no badge). It
            // used to say "complete" on every finished cell, and turned orange while a horizon refinement was pending, which the gui does not.
            if (state != null && state != com.star.proto.FrameProcessingState.FPS_COMPLETE) {
                val s = FrameState.shortString(state)
                if (s.isNotEmpty()) {
                    Text(s, color = StarColors.stateColor(state), fontSize = 10.sp, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.padding(start = 4.dp, bottom = 2.dp))
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

/**
 * Scroll so the item at [index] is in the middle of the view. It is brought into view first, since an item that is not laid out has no
 * size to centre by; the second scroll then moves it down from the top edge by half of what is left.
 */
private suspend fun androidx.compose.foundation.lazy.grid.LazyGridState.centerOn(index: Int, animate: Boolean) {
    scrollToItem(index)
    val item = layoutInfo.visibleItemsInfo.firstOrNull { it.index == index } ?: return
    val offset = -((layoutInfo.viewportSize.height - item.size.height) / 2).coerceAtLeast(0)
    if (animate) animateScrollToItem(index, offset) else scrollToItem(index, offset)
}
