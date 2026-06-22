package com.star.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.unit.*
import com.star.proto.FrameProcessingState
import com.star.proto.FrameViewMode
import com.star.ui.theme.StarColors
import com.star.viewmodel.SequenceViewModel
import kotlinx.coroutines.launch

private const val GRID_CELL_SIZE = 160

/**
 * Lightroom-style thumbnail grid — mirrors GridView.swift.
 * Shows per-frame thumbnails with state badges and selection state.
 */
@Composable
fun GridView(
    sequenceViewModel: SequenceViewModel,
    onFrameSelect: (Int) -> Unit,
) {
    val currentIndex by sequenceViewModel.currentFrameIndex.collectAsState()
    val frameStates by sequenceViewModel.frameStates.collectAsState()
    val frameCount = sequenceViewModel.frameCount

    LazyVerticalGrid(
        columns = GridCells.Adaptive(GRID_CELL_SIZE.dp),
        contentPadding = PaddingValues(8.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.fillMaxSize().background(StarColors.panelBackground),
    ) {
        items(frameCount) { idx ->
            GridCell(
                frameIndex = idx,
                isSelected = idx == currentIndex,
                processingState = frameStates[idx],
                sessionId = sequenceViewModel.sessionId,
                frameRepo = sequenceViewModel.frameRepo,
                imageCache = sequenceViewModel.imageCache,
                onClick = { onFrameSelect(idx) },
            )
        }
    }
}

@Composable
private fun GridCell(
    frameIndex: Int,
    isSelected: Boolean,
    processingState: FrameProcessingState?,
    sessionId: String,
    frameRepo: com.star.data.FrameRepository,
    imageCache: com.star.data.ImageCache,
    onClick: () -> Unit,
) {
    var thumbnail by remember { mutableStateOf<ImageBitmap?>(null) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(frameIndex) {
        scope.launch {
            try {
                val ref = frameRepo.getPreview(sessionId, frameIndex, FrameViewMode.VIEW_ORIGINAL)
                thumbnail = imageCache.load(ref.path)
            } catch (_: Exception) { }
        }
    }

    Box(
        Modifier
            .aspectRatio(4f / 3f)
            .border(
                width = if (isSelected) 2.dp else 0.5.dp,
                color = if (isSelected) Color(0xFF90CAF9) else StarColors.panelBorder,
            )
            .background(Color(0xFF1A1A1A))
            .clickable(onClick = onClick),
    ) {
        thumbnail?.let {
            Image(
                bitmap = it,
                contentDescription = "Frame $frameIndex",
                contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } ?: Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("${frameIndex + 1}", color = StarColors.textSecondary, fontSize = 12.sp)
        }

        // Frame number badge
        Surface(
            Modifier.align(Alignment.BottomStart).padding(4.dp),
            color = Color.Black.copy(alpha = 0.6f),
            shape = MaterialTheme.shapes.extraSmall,
        ) {
            Text(
                "${frameIndex + 1}",
                Modifier.padding(horizontal = 4.dp, vertical = 2.dp),
                color = Color.White,
                fontSize = 10.sp,
            )
        }

        // State badge
        processingState?.let { state ->
            if (state == FrameProcessingState.FPS_COMPLETE) {
                Surface(
                    Modifier.align(Alignment.TopEnd).padding(4.dp),
                    color = Color(0xFF4CAF50).copy(alpha = 0.8f),
                    shape = MaterialTheme.shapes.extraSmall,
                ) {
                    Text("✓", Modifier.padding(horizontal = 4.dp, vertical = 2.dp), color = Color.White, fontSize = 10.sp)
                }
            }
        }
    }
}
