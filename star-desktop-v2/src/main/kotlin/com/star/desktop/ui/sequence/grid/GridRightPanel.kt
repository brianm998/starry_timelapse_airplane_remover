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
import com.star.desktop.ui.theme.StarColors
import com.star.proto.CleanMethod
import com.star.proto.FrameInfo

/** Grid-mode right panel (macOS `GridRightPanel`): thumbnail-size slider, display toggles, frame info. */
@Composable
fun GridRightPanel(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val current by vm.currentIndex.collectAsState()
    val scale by vm.gridThumbnailScale.collectAsState()
    val showFilmstrip by vm.showFilmstrip.collectAsState()
    val states by vm.frameStates.collectAsState()
    var info by remember(current) { mutableStateOf<FrameInfo?>(null) }
    LaunchedEffect(current, states[current]) { info = vm.frameInfo(current) }

    Column(modifier.width(200.dp).fillMaxHeight().background(StarColors.sidePanel)) {
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                SectionTitle("Thumbnail Size")
                Slider(value = scale, onValueChange = vm::setGridThumbnailScale, valueRange = 0.02f..0.5f)
                Text(String.format("%.2f×", scale), color = StarColors.textSecondary, fontSize = 10.sp)
            }

            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                SectionTitle("Display")
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Switch(checked = showFilmstrip, onCheckedChange = { vm.toggleFilmstrip() })
                    Text("Show Filmstrip", color = StarColors.white, fontSize = 11.sp)
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                SectionTitle("Frame")
                InfoRow("Index", "$current")
                states[current]?.let { InfoRow("State", FrameState.shortString(it)) }
            }

            info?.let { fi ->
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SectionTitle("Outliers")
                    InfoRow("Positive", "${fi.numPositiveOutliers}", if (fi.numPositiveOutliers > 0) StarColors.red else StarColors.white)
                    InfoRow("Negative", "${fi.numNegativeOutliers}", if (fi.numNegativeOutliers > 0) StarColors.green else StarColors.white)
                    InfoRow("Undecided", "${fi.numUndecidedOutliers}", if (fi.numUndecidedOutliers > 0) StarColors.orange else StarColors.white)
                }
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SectionTitle("Processing")
                    InfoRow("Mode", cleanMethodName(fi.cleanMethod))
                }
            }
            Text("Double-click a thumbnail to edit", color = StarColors.textDisabled, fontSize = 10.sp)
        }
        PanelChevron("»", { vm.setRightPanel(false) }, Modifier.padding(6.dp))
    }
}

private fun cleanMethodName(m: CleanMethod): String = when (m) {
    CleanMethod.CLEAN_AUTOMATIC_TRUE -> "Auto-Selective"
    CleanMethod.CLEAN_AUTOMATIC -> "Automatic"
    else -> "Selective"
}

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
