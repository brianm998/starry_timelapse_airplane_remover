package com.star.desktop.ui.sequence.grid

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameState
import com.star.desktop.ui.components.PanelChevron
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.sequence.HorizonLineKindToggles
import com.star.desktop.ui.theme.StarColors
import com.star.proto.CleanMethod
import com.star.proto.FrameInfo
import com.star.desktop.i18n.localized

/** Grid-mode right panel (macOS `GridRightPanel`): thumbnail-size slider, display toggles, frame info. */
@Composable
fun GridRightPanel(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val current by vm.currentIndex.collectAsState()
    val scale by vm.gridThumbnailScale.collectAsState()
    val showFilmstrip by vm.showFilmstrip.collectAsState()
    val showHorizon by vm.showHorizonOnMainView.collectAsState()
    val horizonVersion by vm.horizonVersion.collectAsState()
    var overlayExists by remember(current) { mutableStateOf<Boolean?>(null) }
    var pending by remember(current) { mutableStateOf(false) }
    val states by vm.frameStates.collectAsState()
    var info by remember(current) { mutableStateOf<FrameInfo?>(null) }
    LaunchedEffect(current, states[current], horizonVersion) {
        info = vm.frameInfo(current)
        val overlay = vm.horizonOverlay(current, 16, 16)
        overlayExists = overlay?.exists
        pending = overlay?.refinementPending ?: info?.refinementPending ?: false
    }

    Column(modifier.width(200.dp).fillMaxHeight().background(StarColors.sidePanel)) {
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                SectionTitle(localized("ui.thumbnail_size"))
                Slider(value = scale, onValueChange = vm::setGridThumbnailScale, valueRange = 0.02f..0.5f)
                Text(String.format("%.2f×", scale), color = StarColors.textSecondary, fontSize = 10.sp)
            }

            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                SectionTitle(localized("ui.display"))
                // The gui's order: the horizon lines and which kinds, then the filmstrip.
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Switch(checked = showHorizon, onCheckedChange = vm::setShowHorizonOnMainView)
                    Text(localized("ui.show_horizon_lines"), color = StarColors.white, fontSize = 11.sp)
                }
                HorizonLineKindToggles(vm)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Switch(checked = showFilmstrip, onCheckedChange = { vm.toggleFilmstrip() })
                    Text(localized("ui.show_filmstrip"), color = StarColors.white, fontSize = 11.sp)
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                SectionTitle(localized("ui.frame"))
                InfoRow(localized("ui.index"), "$current")
                // The file the frame is from (macOS: the original image's name).
                info?.filename?.takeIf { it.isNotEmpty() }?.let { InfoRow(localized("ui.file"), it) }
                (states[current] ?: info?.state)?.let { InfoRow(localized("ui.state"), FrameState.shortString(it), StarColors.stateColor(it)) }
            }

            // The counts mean something only once the frame's outliers are in memory: a frame still purged to disk reports zeros
            // that are "not known", which the gui leaves out (it shows the section when the frame's outliers are loaded).
            info?.takeIf { it.outliersLoaded }?.let { fi ->
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SectionTitle(localized("ui.outliers"))
                    InfoRow(localized("ui.positive"), "${fi.numPositiveOutliers}", if (fi.numPositiveOutliers > 0) StarColors.red else StarColors.white)
                    InfoRow(localized("ui.negative"), "${fi.numNegativeOutliers}", if (fi.numNegativeOutliers > 0) StarColors.green else StarColors.white)
                    InfoRow(localized("ui.undecided"), "${fi.numUndecidedOutliers}", if (fi.numUndecidedOutliers > 0) StarColors.orange else StarColors.white)
                    InfoRow(localized("ui.trash"), "${fi.numTrashOutliers}", if (fi.numTrashOutliers > 0) StarColors.gray else StarColors.white)
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                SectionTitle(localized("ui.processing"))
                info?.let { InfoRow(localized("ui.mode"), cleanMethodName(it.cleanMethod)) }
                // Whether the horizon is waiting for a refinement, under the mode as in the gui's Processing section.
                if (overlayExists == true) {
                    InfoRow(localized("ui.horizon"), localized(if (pending) "ui.pending" else "ui.set"), if (pending) StarColors.orange else StarColors.green)
                }
            }
            Text(localized("ui.double_click_a_thumbnail_to_edit"), color = StarColors.textDisabled, fontSize = 10.sp)
        }
        PanelChevron("»", { vm.setRightPanel(false) }, Modifier.padding(6.dp))
    }
}

private fun cleanMethodName(m: CleanMethod): String = localized(when (m) {
    CleanMethod.CLEAN_AUTOMATIC_TRUE -> "ui.auto_selective"
    CleanMethod.CLEAN_AUTOMATIC -> "ui.automatic"
    else -> "ui.selective"
})

@Composable
private fun SectionTitle(text: String) =
    Text(text, color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)

@Composable
private fun InfoRow(label: String, value: String, valueColor: Color = StarColors.white) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, color = StarColors.textSecondary, fontSize = 10.sp, modifier = Modifier.width(62.dp))
        Text(value, color = valueColor, fontSize = 10.sp)
    }
}
