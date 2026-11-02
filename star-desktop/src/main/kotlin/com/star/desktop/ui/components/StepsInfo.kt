package com.star.desktop.ui.components

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.ProcessingStepsInfo
import com.star.desktop.i18n.localized
import com.star.desktop.ui.theme.StarColors

/** The circled "i" that asks for the explanation of the steps; the same button as [AlignmentInfoButton], with its own tooltip (macOS `StepsInfoButton`). */
@Composable
fun StepsInfoButton(onClick: () -> Unit) {
    HoverTip(localized("ui.steps_info_help")) {
        Text("ⓘ", color = StarColors.textSecondary, fontSize = 15.sp, modifier = Modifier.padding(horizontal = 6.dp).clickable(onClick = onClick))
    }
}

/**
 * What each step the panel shows does, and which earlier step's results it relies on and why, drawn as a card over a dimmed backdrop
 * like [AlignmentInfoOverlay] (macOS `StepsInfoContent` / `StepsInfoOverlay`).
 */
@Composable
fun StepsInfoOverlay(info: ProcessingStepsInfo, onClose: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.5f)).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .widthIn(max = 540.dp)
                .padding(20.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(localized("ui.steps_info_title"), color = StarColors.white, fontSize = 18.sp)
            Text(info.intro, color = StarColors.textPrimary, fontSize = 12.sp)
            Text(info.subtitle, color = StarColors.textPrimary, fontSize = 12.sp)
            Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                for (entry in info.entries) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(entry.name, color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                        Text(entry.what, color = StarColors.textPrimary, fontSize = 12.sp)
                        Text(entry.needs, color = StarColors.textSecondary, fontSize = 11.sp)
                    }
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Button(onClick = onClose, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) { Text(localized("ui.done")) }
            }
        }
    }
}
