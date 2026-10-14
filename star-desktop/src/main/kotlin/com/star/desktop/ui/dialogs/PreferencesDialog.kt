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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.DetectionPreference
import com.star.desktop.domain.RenderVideo
import com.star.desktop.i18n.localized
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes

/**
 * Preferences (macOS `UserPreferencesEditingView`, on Cmd-,): the choices the app remembers, in the file the Mac app keeps them in, so the two agree.
 * The detection type and the frame rate are shown but not set here: they are the last ones chosen where they are used (the settings, the Render
 * Video dialog). The rest are switches, each with an arrow that opens a sentence on what it does. A switch writes at once; what a switch is read as
 * where it is used is its own (see [com.star.desktop.data.LocalPreferences]), so the "Don't ask me again" on the render prompt, which could
 * not be undone, is undone here.
 */
@Composable
fun PreferencesDialog(app: AppViewModel) {
    val prefs = app.prefs
    var horizonOnMainView by remember { mutableStateOf(prefs.showHorizonOnMainView) }
    var horizonInstructions by remember { mutableStateOf(prefs.showHorizonPainterInstructions) }
    var skipRenderPrompt by remember { mutableStateOf(prefs.skipRenderPromptAfterProcessing) }
    var processingWindow by remember { mutableStateOf(prefs.showProcessingWindow) }

    Box(Modifier.fillMaxSize().background(StarColors.scrim).clickable(enabled = false) {}, contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .widthIn(max = 560.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(localized("ui.preferences"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 22.sp)
            Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                // What was last chosen where it is chosen, which this only reports.
                PreferenceCard(localized("ui.processing_type"), localized("ui.the_detection_method_used_for_outlier"), value = prefs.string(DetectionPreference.KEY))
                PreferenceCard(
                    localized("ui.frame_rate"), localized("ui.the_frame_rate_of_the_incoming_and_outgoing"),
                    value = prefs.videoFrameRate?.let { RenderVideo.rateText(it) } ?: localized("ui.not_set"),
                )
                PreferenceCard(
                    localized("ui.show_horizon_on_main_view"), localized("ui.when_enabled_the_horizon_line_will_be"),
                    checked = horizonOnMainView,
                ) { horizonOnMainView = it; prefs.showHorizonOnMainView = it }
                PreferenceCard(
                    localized("ui.show_horizon_painter_instructions"), localized("ui.when_enabled_startup_instructions_will_be"),
                    checked = horizonInstructions,
                ) { horizonInstructions = it; prefs.showHorizonPainterInstructions = it }
                PreferenceCard(
                    localized("ui.skip_render_prompt_after_processing"), localized("ui.when_enabled_the_render_prompts_before_and"),
                    checked = skipRenderPrompt,
                ) { skipRenderPrompt = it; prefs.setSkipRenderPrompt(it) }
                PreferenceCard(
                    localized("ui.show_processing_window"), localized("ui.when_enabled_a_window_showing_each"),
                    checked = processingWindow,
                ) { processingWindow = it; prefs.showProcessingWindow = it }
            }
            Row(Modifier.fillMaxWidth()) {
                Button(onClick = app::closePreferences, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) { Text(localized("ui.close")) }
            }
        }
    }
}

/** One preference: its name, its value (a switch to change it, or the text it holds), and an arrow that opens what it is for. */
@Composable
private fun PreferenceCard(title: String, info: String, value: String? = null, checked: Boolean? = null, onChecked: (Boolean) -> Unit = {}) {
    var open by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).background(StarColors.sidePanel).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(title, color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, modifier = Modifier.weight(1f))
            if (checked != null) Switch(checked = checked, onCheckedChange = onChecked)
            Text(
                if (open) "▴" else "▾", color = StarColors.accent, fontSize = 16.sp,
                modifier = Modifier.clip(RoundedCornerShape(10.dp)).clickable { open = !open }.padding(horizontal = 8.dp),
            )
        }
        if (value != null) Text(value, color = StarColors.textSecondary, fontSize = 12.sp)
        if (open) {
            Text(
                info, color = StarColors.textPrimary, fontSize = 13.sp,
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp)).background(StarColors.cellDefault).padding(8.dp),
            )
        }
    }
}
