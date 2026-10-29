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
import com.star.desktop.i18n.localized
import com.star.desktop.ui.theme.StarColors

/** The circled "i" that asks for the explanation of the alignment charts (macOS `AlignmentInfoButton`). */
@Composable
fun AlignmentInfoButton(onClick: () -> Unit) {
    HoverTip(localized("ui.alignment_info_help")) {
        Text("ⓘ", color = StarColors.textSecondary, fontSize = 15.sp, modifier = Modifier.padding(horizontal = 6.dp).clickable(onClick = onClick))
    }
}

/**
 * What the alignment charts show and how to read them, in words a user who has never heard of a homography can follow, drawn as a card over a
 * dimmed backdrop (macOS `AlignmentInfoContent` / `AlignmentInfoOverlay`). What a good chart looks like depends on whether the camera moved:
 * flat, evenly spaced lines when it did not, a steady mirrored curve when it did.
 */
@Composable
fun AlignmentInfoOverlay(cameraMoving: Boolean, onClose: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.5f)).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .widthIn(max = 540.dp)
                .padding(20.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(localized("ui.alignment_info_title"), color = StarColors.white, fontSize = 18.sp)
            Section("ui.alignment_info_what_title", "ui.alignment_info_what_body")
            Section("ui.alignment_info_good_title", if (cameraMoving) "ui.alignment_info_good_body_moving" else "ui.alignment_info_good_body_fixed")
            Section("ui.alignment_info_bad_title", if (cameraMoving) "ui.alignment_info_bad_body_moving" else "ui.alignment_info_bad_body_fixed")
            Text(localized("ui.alignment_info_use_body"), color = StarColors.textSecondary, fontSize = 11.sp)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Button(onClick = onClose, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) { Text(localized("ui.done")) }
            }
        }
    }
}

@Composable
private fun Section(titleKey: String, bodyKey: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(localized(titleKey), color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
        Text(localized(bodyKey), color = StarColors.textPrimary, fontSize = 12.sp)
    }
}
