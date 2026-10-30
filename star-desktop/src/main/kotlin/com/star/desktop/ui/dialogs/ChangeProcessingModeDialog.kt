package com.star.desktop.ui.dialogs

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.components.modalScrim
import com.star.desktop.ui.components.defaultAction
import com.star.desktop.i18n.localized
import com.star.desktop.ui.components.VerticalStarPicker
import com.star.desktop.ui.theme.StarColors
import com.star.proto.CleanMethod

/** Catalogue key of a frame mode's name, as the macOS panel and change-mode dialog show it. */
internal fun frameModeNameKey(m: CleanMethod) = when (m) {
    CleanMethod.CLEAN_AUTOMATIC -> "ui.frame_mode_automatic"
    CleanMethod.CLEAN_AUTOMATIC_TRUE -> "ui.frame_mode_auto_selective"
    else -> "ui.frame_mode_selective"
}

private fun descriptionKey(m: CleanMethod) = when (m) {
    CleanMethod.CLEAN_AUTOMATIC -> "ui.frame_mode_desc_automatic"
    CleanMethod.CLEAN_AUTOMATIC_TRUE -> "ui.frame_mode_desc_auto_selective"
    else -> "ui.frame_mode_desc_selective"
}

/**
 * Changes one frame's processing mode (macOS `ChangeProcessingModeView`). The Clean and Auto Select choices are held here and only
 * reach the frame through [onConfirm] when OK is pressed; [onCancel] leaves it as it was.
 */
@Composable
fun ChangeProcessingModeDialog(current: CleanMethod, onCancel: () -> Unit, onConfirm: (CleanMethod) -> Unit) {
    var automatic by remember { mutableStateOf(current != CleanMethod.CLEAN_SELECTIVE) }
    var autoSelect by remember { mutableStateOf(current == CleanMethod.CLEAN_AUTOMATIC_TRUE) }
    val chosen = when {
        !automatic -> CleanMethod.CLEAN_SELECTIVE
        autoSelect -> CleanMethod.CLEAN_AUTOMATIC_TRUE
        else -> CleanMethod.CLEAN_AUTOMATIC
    }
    val changed = chosen != current

    Box(
        // Return confirms what is chosen (OK does nothing when it is what the frame already has, so neither does Return) and Esc cancels.
        Modifier.fillMaxSize().background(Color(0.5f, 0.5f, 0.5f, 0.5f)).modalScrim()
            .defaultAction({ if (changed) onConfirm(chosen) }, onEscape = onCancel),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .widthIn(max = 460.dp)
                .clip(RoundedCornerShape(20.dp))
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(localized("ui.change_mode_title"), color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 22.sp)

            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    localized("ui.processing_mode_current", localized(frameModeNameKey(current))),
                    color = StarColors.white, fontWeight = FontWeight.Bold, fontSize = 13.sp,
                )
                Text(localized(descriptionKey(current)), color = StarColors.white, fontSize = 13.sp)
            }

            Text(localized("ui.clean"), color = StarColors.white, fontSize = 12.sp)
            VerticalStarPicker(
                options = listOf(true, false),
                selected = automatic,
                label = { localized(if (it) "ui.automatic" else "ui.selective") },
                onSelect = { automatic = it },
                modifier = Modifier.fillMaxWidth(),
            )

            Column(Modifier.alpha(if (automatic) 1f else 0.4f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(localized("ui.auto_select"), color = StarColors.white, fontSize = 12.sp)
                VerticalStarPicker(
                    options = listOf(true, false),
                    selected = autoSelect,
                    label = { localized(if (it) "ui.yes" else "ui.no") },
                    onSelect = { if (automatic) autoSelect = it },
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            if (changed) {
                Text(
                    localized("ui.change_mode_summary", localized(frameModeNameKey(current)), localized(frameModeNameKey(chosen)), localized(descriptionKey(chosen))),
                    color = StarColors.white, fontSize = 13.sp,
                )
            } else {
                Text(localized("ui.change_mode_none"), color = StarColors.textSecondary, fontSize = 13.sp)
            }

            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Button(
                    onClick = onCancel,
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.gray),
                ) { Text(localized("ui.cancel")) }
                Spacer(Modifier.weight(1f))
                Button(
                    onClick = { onConfirm(chosen) },
                    enabled = changed,
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                ) { Text(localized("ui.ok")) }
            }
        }
    }
}
