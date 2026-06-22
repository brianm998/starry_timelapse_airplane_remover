package com.star.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.*
import com.star.data.ProcessingStatus
import com.star.proto.FrameProcessingState
import com.star.proto.IoProgress
import com.star.ui.theme.StarColors
import com.star.viewmodel.SequenceViewModel

/**
 * Processing progress bars and per-frame state grid.
 * Mirrors ProgressBars.swift + BlobProcessingView.swift + CircularProgressView.swift.
 */
@Composable
fun ProgressSection(
    sequenceViewModel: SequenceViewModel,
    modifier: Modifier = Modifier,
) {
    val processingStatus by sequenceViewModel.processingStatus.collectAsState()
    val frameStates by sequenceViewModel.frameStates.collectAsState()
    val ioProgress by sequenceViewModel.ioProgress.collectAsState()

    Column(modifier) {
        // Status text
        val statusText = when (processingStatus) {
            is ProcessingStatus.Idle      -> "Idle"
            is ProcessingStatus.Running   -> "Processing…"
            is ProcessingStatus.Cancelling -> "Cancelling…"
            is ProcessingStatus.Finished  -> "Done"
            is ProcessingStatus.Error     -> "Error: ${(processingStatus as ProcessingStatus.Error).message}"
        }
        Text(statusText, color = StarColors.textSecondary, fontSize = 11.sp)

        if (processingStatus is ProcessingStatus.Running) {
            Spacer(Modifier.height(4.dp))
            LinearProgressIndicator(
                modifier = Modifier.fillMaxWidth(),
                color = Color(0xFF90CAF9),
            )
        }

        // I/O progress (decode/encode)
        ioProgress?.let { io ->
            Spacer(Modifier.height(4.dp))
            LinearProgressIndicator(
                progress = { if (io.total > 0) io.current.toFloat() / io.total else 0f },
                modifier = Modifier.fillMaxWidth(),
                color = Color(0xFF4CAF50),
            )
            Text(
                "${io.current} / ${io.total}",
                color = StarColors.textSecondary,
                fontSize = 10.sp,
            )
        }

        // Per-frame state grid (compact dots)
        if (frameStates.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            FrameStateGrid(frameStates = frameStates, frameCount = sequenceViewModel.frameCount)
        }
    }
}

/** A compact grid of colored dots — one per frame, showing processing state. */
@Composable
private fun FrameStateGrid(
    frameStates: Map<Int, FrameProcessingState>,
    frameCount: Int,
) {
    val dotSize = 6.dp
    val dotsPerRow = 32

    Column {
        Text("Frame states", color = StarColors.textSecondary, fontSize = 10.sp)
        Spacer(Modifier.height(4.dp))
        LazyVerticalGrid(
            columns = GridCells.Fixed(dotsPerRow),
            modifier = Modifier.heightIn(max = 80.dp),
            verticalArrangement = Arrangement.spacedBy(1.dp),
            horizontalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            items(frameCount) { idx ->
                val state = frameStates[idx]
                Box(
                    Modifier
                        .size(dotSize)
                        .background(
                            color = dotColor(state),
                            shape = MaterialTheme.shapes.extraSmall,
                        ),
                )
            }
        }
    }
}

private fun dotColor(state: FrameProcessingState?): Color = when (state) {
    null, FrameProcessingState.FPS_UNPROCESSED -> Color(0xFF333333)
    FrameProcessingState.FPS_COMPLETE          -> Color(0xFF4CAF50)  // green
    FrameProcessingState.FPS_WRITING_OUTPUT_FILE,
    FrameProcessingState.FPS_ASSEMBLING_PROCESSED_FRAME -> Color(0xFFFF9800)  // orange
    FrameProcessingState.FPS_OUTLIER_PROCESSING_COMPLETE,
    FrameProcessingState.FPS_FIRST_CLASSIFICATION,
    FrameProcessingState.FPS_SECOND_CLASSIFICATION -> Color(0xFF9C27B0)  // purple
    else -> Color(0xFF2196F3)  // blue — in progress
}
