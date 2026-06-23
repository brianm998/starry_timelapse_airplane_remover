package com.star.desktop.ui.sequence.grid

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
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
import androidx.compose.material3.Text
import com.star.desktop.domain.FrameState
import com.star.desktop.domain.InteractionMode
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.FrameProcessingState

/** Grid mode (macOS `GridView`): Lightroom-style adaptive thumbnail grid; double-click → edit. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun GridView(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val states by vm.frameStates.collectAsState()
    val current by vm.currentIndex.collectAsState()
    val selected by vm.selected.collectAsState()

    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 200.dp),
        modifier = modifier.fillMaxSize().background(StarColors.appBackground),
        contentPadding = PaddingValues(8.dp),
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(4.dp),
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(4.dp),
    ) {
        items((0 until vm.frameCount).toList(), key = { it }) { i ->
            GridCell(
                vm = vm,
                index = i,
                isCurrent = i == current,
                isSelected = i in selected,
                state = states[i],
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GridCell(
    vm: SequenceViewModel,
    index: Int,
    isCurrent: Boolean,
    isSelected: Boolean,
    state: FrameProcessingState?,
) {
    var thumb by remember(index) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(index, state) { if (thumb == null) thumb = vm.loadThumb(index) }

    val bg = when {
        isCurrent -> StarColors.cellHighlighted
        isSelected -> StarColors.cellSelected
        else -> StarColors.cellDefault
    }

    Column(
        Modifier
            .clip(StarShapes.gridCell)
            .background(bg)
            .then(if (isCurrent) Modifier.border(2.dp, SolidColor(StarColors.accent), StarShapes.gridCell) else Modifier)
            .combinedClickable(
                onClick = { vm.select(index) },
                onDoubleClick = {
                    vm.setCurrentIndex(index)
                    vm.setMode(InteractionMode.EDIT)
                },
            )
            .padding(4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.fillMaxWidth().aspectRatio(1.5f).clip(StarShapes.gridCell), contentAlignment = Alignment.Center) {
            val t = thumb
            if (t != null) {
                Image(bitmap = t, contentDescription = "Frame $index", modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            } else {
                Text("${index + 1}", color = StarColors.textSecondary, fontSize = 16.sp)
            }
        }
        Text(
            "${index + 1} · ${state?.let { FrameState.shortString(it) } ?: "—"}",
            color = if (state == FrameProcessingState.FPS_COMPLETE) StarColors.green else StarColors.textDisabled,
            fontSize = 10.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 2.dp),
        )
    }
}
