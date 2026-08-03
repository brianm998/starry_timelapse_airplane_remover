package com.star.desktop.ui.sequence

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameState
import com.star.desktop.ui.sequence.grid.CleanMethodIcon
import com.star.desktop.ui.theme.StarColors
import com.star.proto.FrameInfo
import com.star.proto.FrameProcessingState
import com.star.desktop.i18n.localized

/** Filmstrip cell width (macOS thumbnailWidth + an 8pt cell margin so flush cells leave a thumbnail gutter). */
private val CELL_WIDTH = 116.dp

/** Horizontal filmstrip (macOS `FilmstripView`): flush thumbnails + status overlays, auto-scroll to current. */
@Composable
fun Filmstrip(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val current by vm.currentIndex.collectAsState()
    val selected by vm.selected.collectAsState()
    val states by vm.frameStates.collectAsState()
    val listState = rememberLazyListState()

    LaunchedEffect(current) {
        if (current in 0 until vm.frameCount) listState.animateScrollToItem(current)
    }

    LazyRow(
        state = listState,
        modifier = modifier.fillMaxWidth().height(100.dp).background(StarColors.appBackground),
        contentPadding = PaddingValues(0.dp),
        horizontalArrangement = Arrangement.spacedBy(0.dp),
    ) {
        items((0 until vm.frameCount).toList(), key = { it }) { i ->
            FilmstripCell(
                vm = vm,
                index = i,
                isCurrent = i == current,
                isInSelection = i != current && i in selected,
                state = states[i],
            )
        }
    }
}

@Composable
private fun FilmstripCell(
    vm: SequenceViewModel,
    index: Int,
    isCurrent: Boolean,
    isInSelection: Boolean,
    state: FrameProcessingState?,
) {
    var thumb by remember(index) { mutableStateOf<ImageBitmap?>(null) }
    var info by remember(index) { mutableStateOf<FrameInfo?>(null) }
    // Reload when the frame's processing state changes — its preview/counts may now exist.
    LaunchedEffect(index, state) { if (thumb == null) thumb = vm.loadThumb(index) }
    LaunchedEffect(index, state) { info = vm.frameInfo(index) }

    // The streamed state updates live during processing; `Frame.Get` is the source of truth on open
    // (the stream is empty until processing runs, so a fresh sequence reports `unprocessed` only here).
    val effectiveState = state ?: info?.state

    // Selection tiers mirror macOS `filmstripBackground`/`filmstripBorder` (sharp-cornered rectangle):
    // current → bright grey + 2dp accent border, multi-selected → mid grey + 1dp 55% accent, else dark grey.
    val bg = when {
        isCurrent -> StarColors.cellHighlighted
        isInSelection -> StarColors.cellSelected
        else -> StarColors.cellDefault
    }
    val borderMod = when {
        isCurrent -> Modifier.border(2.dp, StarColors.accent, RectangleShape)
        isInSelection -> Modifier.border(1.dp, StarColors.accent.copy(alpha = 0.55f), RectangleShape)
        else -> Modifier
    }
    // Clean-method glyph is green once complete, grey otherwise (macOS `processingColor`).
    val processingColor = if (effectiveState == FrameProcessingState.FPS_COMPLETE) StarColors.green else StarColors.gray
    val aspect = if (vm.info.imageHeight > 0) vm.info.imageWidth.toFloat() / vm.info.imageHeight else 1.5f

    Column(
        modifier = Modifier
            .width(CELL_WIDTH)
            .fillMaxHeight()
            .background(bg)
            .then(borderMod)
            .clickable { vm.select(index) },
    ) {
        // Top strip: frame index on the left, outlier + clean-method badges on the right.
        Row(
            modifier = Modifier.fillMaxWidth().height(16.dp).padding(start = 8.dp, end = 4.dp, top = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("$index", color = StarColors.white, fontSize = 11.sp)
            Box(Modifier.weight(1f))
            val fi = info
            if (fi != null) {
                Row(horizontalArrangement = Arrangement.spacedBy((-4).dp), verticalAlignment = Alignment.CenterVertically) {
                    if (fi.numPositiveOutliers != 0) OutlierTick(StarColors.red)
                    if (fi.numUndecidedOutliers != 0) OutlierTick(StarColors.orange)
                    if (fi.numNegativeOutliers != 0) OutlierTick(StarColors.green)
                }
                Box(Modifier.padding(start = 3.dp)) { CleanMethodIcon(fi.cleanMethod, processingColor, 9.dp) }
            }
        }

        // Thumbnail with the processing-state label overlaid at the bottom-left (macOS ZStack).
        Box(
            Modifier.fillMaxWidth().weight(1f).padding(horizontal = 4.dp, vertical = 2.dp),
            contentAlignment = Alignment.Center,
        ) {
            Box(Modifier.fillMaxWidth().aspectRatio(aspect), contentAlignment = Alignment.BottomStart) {
                val t = thumb
                if (t != null) {
                    Image(
                        bitmap = t,
                        contentDescription = localized("ui.frame_n", index),
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Crop,
                    )
                }
                // macOS `frameState.shortString` is empty for `.complete`, so only label in-progress frames.
                if (effectiveState != null && effectiveState != FrameProcessingState.FPS_COMPLETE) {
                    Text(
                        FrameState.shortString(effectiveState),
                        color = StarColors.stateColor(effectiveState),
                        fontSize = 11.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(start = 4.dp, bottom = 2.dp),
                    )
                }
            }
        }
    }
}

/** A small diagonal stroke standing in for the macOS `line.diagonal` outlier indicator. */
@Composable
private fun OutlierTick(color: androidx.compose.ui.graphics.Color) {
    Text("╱", color = color, fontSize = 9.sp)
}
