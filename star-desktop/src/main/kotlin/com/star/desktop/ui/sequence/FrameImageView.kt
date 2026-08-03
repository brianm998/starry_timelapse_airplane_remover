package com.star.desktop.ui.sequence

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameState
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.i18n.localized

/**
 * The center frame display: shows the current frame's preview image (aspect-fit). Until processing
 * has generated a preview for the frame, shows a placeholder reflecting the frame's processing state
 * (the daemon writes previews only as frames complete).
 */
@Composable
fun FrameImageView(vm: SequenceViewModel, background: Color = StarColors.appBackground, modifier: Modifier = Modifier) {
    val bmp by vm.currentPreview.collectAsState()
    val available by vm.previewAvailable.collectAsState()
    val idx by vm.currentIndex.collectAsState()
    val states by vm.frameStates.collectAsState()
    val processing by vm.isProcessing.collectAsState()

    Box(modifier.fillMaxSize().background(background), contentAlignment = Alignment.Center) {
        val current = bmp
        if (current != null) {
            Image(
                bitmap = current,
                contentDescription = localized("ui.frame_n", idx),
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Fit,
            )
        } else {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (processing) CircularProgressIndicator(color = StarColors.accent)
                val state = states[idx]
                val label = when {
                    !available && state != null -> localized("ui.frame_n_state", idx, FrameState.shortString(state))
                    !available -> localized("ui.frame_n_unprocessed", idx)
                    else -> "Loading frame $idx…"
                }
                Text(label, color = StarColors.textSecondary, fontSize = 13.sp)
                if (!available && !processing) {
                    Text(localized("ui.run_processing_to_generate_previews"), color = StarColors.textDisabled, fontSize = 11.sp)
                }
            }
        }
    }
}
