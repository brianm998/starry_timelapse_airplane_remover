package com.star.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.*
import androidx.compose.ui.unit.*
import com.star.proto.FrameProcessingState
import com.star.proto.FrameViewMode
import com.star.ui.theme.StarColors
import com.star.viewmodel.SequenceViewModel
import kotlinx.coroutines.launch

private const val THUMB_WIDTH = 80
private const val THUMB_HEIGHT = 60

/**
 * Horizontal filmstrip below the frame view — mirrors FilmstripView.swift.
 * Each cell shows a thumbnail and a state badge.
 */
@Composable
fun FilmstripView(
    sequenceViewModel: SequenceViewModel,
    modifier: Modifier = Modifier,
) {
    val currentIndex by sequenceViewModel.currentFrameIndex.collectAsState()
    val frameStates by sequenceViewModel.frameStates.collectAsState()
    val frameCount = sequenceViewModel.frameCount
    val imageCache = sequenceViewModel.imageCache
    val scope = rememberCoroutineScope()

    val listState = rememberLazyListState()

    // Auto-scroll to keep current frame visible
    LaunchedEffect(currentIndex) {
        listState.animateScrollToItem(currentIndex)
    }

    LazyRow(
        state = listState,
        modifier = modifier
            .fillMaxWidth()
            .background(StarColors.filmstripBg),
        contentPadding = PaddingValues(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        items(frameCount) { idx ->
            FilmstripCell(
                frameIndex = idx,
                isSelected = idx == currentIndex,
                processingState = frameStates[idx],
                sessionId = sequenceViewModel.sessionId,
                frameRepo = sequenceViewModel.frameRepo,
                imageCache = imageCache,
                onClick = { sequenceViewModel.goToFrame(idx) },
            )
        }
    }
}

@Composable
private fun FilmstripCell(
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
            .size(THUMB_WIDTH.dp, THUMB_HEIGHT.dp)
            .border(
                width = if (isSelected) 2.dp else 0.dp,
                color = if (isSelected) Color(0xFF90CAF9) else Color.Transparent,
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
            Text("$frameIndex", color = StarColors.textSecondary, fontSize = 9.sp)
        }

        // State indicator dot
        processingState?.let { state ->
            Box(
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(2.dp)
                    .size(6.dp)
                    .background(stateColor(state), shape = MaterialTheme.shapes.small),
            )
        }
    }
}

private fun stateColor(state: FrameProcessingState): Color = when (state) {
    FrameProcessingState.FPS_COMPLETE -> Color(0xFF4CAF50)  // green
    FrameProcessingState.FPS_WRITING_OUTPUT_FILE -> Color(0xFFFF9800)  // orange
    FrameProcessingState.FPS_UNPROCESSED -> Color.Transparent
    else -> Color(0xFF2196F3)  // blue — in progress
}
