package com.star.desktop.ui.sequence

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameState
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.FrameProcessingState

/** Horizontal filmstrip (macOS `FilmstripView`): thumbnails + state badges, auto-scroll to current. */
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
        modifier = modifier.fillMaxWidth().height(96.dp).background(StarColors.appBackground),
        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        items((0 until vm.frameCount).toList(), key = { it }) { i ->
            FilmstripCell(vm, i, isCurrent = i == current, isSelected = i in selected, state = states[i])
        }
    }
}

@Composable
private fun FilmstripCell(
    vm: SequenceViewModel,
    index: Int,
    isCurrent: Boolean,
    isSelected: Boolean,
    state: FrameProcessingState?,
) {
    var thumb by remember(index) { mutableStateOf<ImageBitmap?>(null) }
    // Reload when the frame's processing state changes — its preview may now exist.
    LaunchedEffect(index, state) { if (thumb == null) thumb = vm.loadThumb(index) }

    val bg = when {
        isCurrent -> StarColors.cellHighlighted
        isSelected -> StarColors.cellSelected
        else -> StarColors.cellDefault
    }

    Column(
        modifier = Modifier
            .width(110.dp)
            .clip(StarShapes.gridCell)
            .background(bg)
            .then(if (isCurrent) Modifier.border(2.dp, SolidColor(StarColors.accent), StarShapes.gridCell) else Modifier)
            .clickable { vm.select(index) }
            .padding(3.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.fillMaxWidth().aspectRatio(1.5f).clip(StarShapes.gridCell), contentAlignment = Alignment.Center) {
            val t = thumb
            if (t != null) {
                Image(bitmap = t, contentDescription = "Frame $index", modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            } else {
                androidx.compose.material3.Text("${index + 1}", color = StarColors.textSecondary, fontSize = 12.sp)
            }
        }
        androidx.compose.material3.Text(
            state?.let { FrameState.shortString(it) } ?: "${index + 1}",
            color = if (state == FrameProcessingState.FPS_COMPLETE) StarColors.green else StarColors.textDisabled,
            fontSize = 8.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
