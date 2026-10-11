package com.star.desktop.ui.dialogs

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.ToolType
import com.star.desktop.i18n.localized
import com.star.desktop.ui.components.toolPainter
import com.star.desktop.ui.theme.StarColors

/** Detailed explanation of every editing tool (macOS `ToolHelpView`); opened by the "i" in the right panel. */
@Composable
fun ToolHelpDialog(onClose: () -> Unit) {
    Box(
        Modifier.fillMaxSize().background(Color(0.5f, 0.5f, 0.5f, 0.5f)).clickable(onClick = onClose),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .widthIn(max = 620.dp)
                .fillMaxHeight(0.8f)
                .clip(RoundedCornerShape(20.dp))
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(localized("ui.tool_help_title"), color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 24.sp)
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(localized("ui.tool_help_intro"), color = StarColors.white, fontSize = 13.sp)
                Text(localized("ui.tool_help_selective"), color = StarColors.white, fontSize = 13.sp)
                ToolType.selectable.forEach { t ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(toolPainter(t), contentDescription = t.displayName, tint = Color.Unspecified, modifier = Modifier.size(35.dp))
                        Column {
                            Text(t.displayName, color = StarColors.white, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                            Text(t.helpText, color = StarColors.white, fontSize = 13.sp)
                        }
                    }
                }
                Text(localized("ui.tool_help_drag_note"), color = StarColors.white, fontSize = 13.sp)
            }
            Button(onClick = onClose, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) {
                Text(localized("ui.close"))
            }
        }
    }
}
