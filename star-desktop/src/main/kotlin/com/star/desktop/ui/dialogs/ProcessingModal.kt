package com.star.desktop.ui.dialogs

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.FrameProcessingState
import com.star.desktop.i18n.localized

/**
 * Processing progress screen (macOS `ProcessingModalView`): shows how far the run has gone, with a
 * Stop button (cancels the run) and a Dismiss button that only hides this screen — the run keeps
 * going in the background, so the user can inspect results while other frames still process.
 */
@Composable
fun ProcessingModal(svm: SequenceViewModel) {
    val frameStates by svm.frameStates.collectAsState()
    val frameCount = svm.frameCount
    val done = frameStates.values.count { it == FrameProcessingState.FPS_COMPLETE }
    val fraction = if (frameCount > 0) done.toFloat() / frameCount else 0f

    Box(Modifier.fillMaxSize().background(StarColors.scrim), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .widthIn(min = 380.dp, max = 480.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(localized("ui.processing"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
            Text(
                "$done of $frameCount frames complete",
                color = StarColors.textSecondary, fontSize = 13.sp,
            )
            LinearProgressIndicator(
                progress = { fraction },
                modifier = Modifier.fillMaxWidth().height(8.dp).clip(RoundedCornerShape(4.dp)),
                color = StarColors.accent,
            )
            Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                OutlinedButton(onClick = svm::dismissProcessingModal) { Text(localized("ui.dismiss")) }
                Button(
                    onClick = svm::cancelProcessing,
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                ) { Text(localized("ui.stop")) }
            }
        }
    }
}
