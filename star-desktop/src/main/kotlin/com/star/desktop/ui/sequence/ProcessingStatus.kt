package com.star.desktop.ui.sequence

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameState
import com.star.desktop.domain.InteractionMode
import com.star.desktop.i18n.localized
import com.star.desktop.ui.components.HoverTip
import com.star.desktop.ui.theme.StarColors

/**
 * What is going on, while a run is (macOS `BottomRightView`): a spinner, how much is left, and a red Stop. In every mode: edit counts the
 * frames being worked on now, scrub and grid the frames still to do. It shows nothing when nothing is running.
 */
@Composable
fun ProcessingStatus(vm: SequenceViewModel, mode: InteractionMode) {
    val processing by vm.isProcessing.collectAsState()
    if (!processing) return
    val states by vm.frameStates.collectAsState()
    val text = if (mode == InteractionMode.EDIT) {
        localized("ui.n_frames_processing", states.values.count(FrameState::isWorking))
    } else {
        localized("ui.processing_n_more_frames", (vm.frameCount - states.values.count(FrameState::isComplete)).coerceAtLeast(0))
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CircularProgressIndicator(Modifier.size(16.dp), color = StarColors.white, strokeWidth = 2.dp)
        Text(text, color = StarColors.white, fontSize = 12.sp)
        HoverTip(localized("ui.cancel_all_pending_processing_operations")) {
            Text(
                localized("ui.stop"),
                color = Color.White,
                fontSize = 12.sp,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .background(Color.Red.copy(alpha = 0.8f))
                    .clickable { vm.cancelProcessing() }
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }
    }
}
