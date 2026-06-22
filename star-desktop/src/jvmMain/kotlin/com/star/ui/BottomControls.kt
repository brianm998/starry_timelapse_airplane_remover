package com.star.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.*
import com.star.ui.theme.StarColors
import com.star.viewmodel.SequenceViewModel
import kotlinx.coroutines.*

/**
 * Bottom control bar: scrub slider + playback controls + frame number + filmstrip.
 * Mirrors BottomControls.swift, ScrubSliderView.swift, VideoPlaybackButtons.swift,
 * EditableFrameNumberView.swift, FilmstripView.swift.
 */
@Composable
fun BottomControls(
    sequenceViewModel: SequenceViewModel,
    modifier: Modifier = Modifier,
) {
    val currentIndex by sequenceViewModel.currentFrameIndex.collectAsState()
    val frameCount = sequenceViewModel.frameCount
    var isPlaying by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var playJob by remember { mutableStateOf<Job?>(null) }

    Column(modifier) {
        // Filmstrip
        FilmstripView(
            sequenceViewModel = sequenceViewModel,
            modifier = Modifier.fillMaxWidth().weight(1f),
        )

        // Scrub slider + playback controls row
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Playback: ◀◀ ◀ ▶/⏸ ▶ ▶▶
            IconButton(onClick = { sequenceViewModel.goToFrame(0) }) {
                Text("⏮", color = StarColors.textPrimary)
            }
            IconButton(onClick = { sequenceViewModel.prevFrame() }) {
                Text("◀", color = StarColors.textPrimary)
            }
            IconButton(onClick = {
                isPlaying = !isPlaying
                if (isPlaying) {
                    playJob = scope.launch {
                        while (isActive && isPlaying) {
                            sequenceViewModel.nextFrame()
                            delay(100)  // ~10 fps playback
                        }
                    }
                } else {
                    playJob?.cancel()
                }
            }) {
                Text(if (isPlaying) "⏸" else "▶", color = StarColors.textPrimary)
            }
            IconButton(onClick = { sequenceViewModel.nextFrame() }) {
                Text("▶", color = StarColors.textPrimary)
            }
            IconButton(onClick = { sequenceViewModel.goToFrame(frameCount - 1) }) {
                Text("⏭", color = StarColors.textPrimary)
            }

            // Scrub slider
            Slider(
                value = if (frameCount > 1) currentIndex.toFloat() / (frameCount - 1) else 0f,
                onValueChange = { v ->
                    sequenceViewModel.goToFrame((v * (frameCount - 1)).toInt())
                },
                modifier = Modifier.weight(1f),
                colors = SliderDefaults.colors(
                    thumbColor = Color(0xFF90CAF9),
                    activeTrackColor = Color(0xFF90CAF9),
                ),
            )

            // Editable frame number
            Text(
                "${currentIndex + 1} / $frameCount",
                color = StarColors.textPrimary,
                fontSize = 12.sp,
                modifier = Modifier.widthIn(min = 72.dp),
            )
        }
    }
}
