package com.star.desktop.ui.dialogs

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.desktop.i18n.localized

/** Pre-processing prompt (macOS `PreProcessingRenderPromptView`): auto-render after processing? */
@Composable
fun PreProcessingRenderPrompt(app: AppViewModel) {
    PromptCard(onScrimClick = app::dismissPreRenderPrompt) {
        Text(localized("ui.render_video_after_processing"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
        Text(
            localized("ui.once_frame_processing_finishes_would_you"),
            color = StarColors.textSecondary, fontSize = 13.sp,
        )
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = { app.confirmStartProcessing(autoRender = false, dontAskAgain = true) }) {
                Text(localized("ui.don_t_ask_me_again"))
            }
            Box(Modifier.weight(1f))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = { app.confirmStartProcessing(autoRender = false, dontAskAgain = false) }) { Text(localized("ui.no")) }
                Button(
                    onClick = { app.confirmStartProcessing(autoRender = true, dontAskAgain = false) },
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                ) { Text(localized("ui.yes")) }
            }
        }
    }
}

/** Post-processing prompt (macOS `PostProcessingRenderPromptView`): render now / preview / cancel. */
@Composable
fun PostProcessingRenderPrompt(app: AppViewModel) {
    PromptCard(onScrimClick = app::dismissPostRenderPrompt) {
        Text(localized("ui.processing_complete"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
        Text(localized("ui.render_video_now"), color = StarColors.textSecondary, fontSize = 15.sp)
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = app::dismissPostRenderPrompt) { Text(localized("ui.cancel")) }
            Box(Modifier.weight(1f))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = app::previewFinalFrames) { Text(localized("ui.preview_first")) }
                Button(
                    onClick = app::confirmRenderAfterProcessing,
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                ) { Text(localized("ui.yes")) }
            }
        }
    }
}

@Composable
private fun PromptCard(onScrimClick: () -> Unit, content: @Composable () -> Unit) {
    Box(
        Modifier.fillMaxSize().background(StarColors.scrim).clickable(onClick = onScrimClick),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .widthIn(min = 380.dp, max = 520.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) { content() }
    }
}
