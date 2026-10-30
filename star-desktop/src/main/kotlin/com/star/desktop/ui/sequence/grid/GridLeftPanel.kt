package com.star.desktop.ui.sequence.grid

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.ViewModes
import com.star.desktop.ui.components.PanelChevron
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.proto.FrameViewMode
import com.star.desktop.i18n.localized

/** Grid-mode left panel (macOS `GridLeftPanel`): the "Show" view-mode picker driving every thumbnail. */
@Composable
fun GridLeftPanel(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val viewMode by vm.viewMode.collectAsState()
    val current by vm.currentIndex.collectAsState()
    val states by vm.frameStates.collectAsState()
    var available by remember { mutableStateOf<List<FrameViewMode>>(emptyList()) }
    // Recompute when the frame changes or its processing state advances (new images may now exist).
    LaunchedEffect(current, states[current]) { available = vm.availableViewModes(current) }
    Column(modifier.width(160.dp).fillMaxHeight().background(StarColors.gridLeftPanel)) {
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(localized("ui.show"), color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            com.star.desktop.ui.components.VerticalStarPicker(
                options = ViewModes.gridShown(available),
                selected = viewMode,
                label = { ViewModes.longName(it) },
                onSelect = { vm.setViewMode(it) },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        PanelChevron("«", { vm.setLeftPanel(false) }, Modifier.padding(6.dp))
    }
}
