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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.components.PanelChevron
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.proto.FrameViewMode

/** Grid-mode left panel (macOS `GridLeftPanel`): the "Show" view-mode picker driving every thumbnail. */
@Composable
fun GridLeftPanel(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val viewMode by vm.viewMode.collectAsState()
    Column(modifier.width(160.dp).fillMaxHeight().background(StarColors.gridLeftPanel)) {
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Show", color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            val labels = SHOW_MODES.toMap()
            com.star.desktop.ui.components.VerticalStarPicker(
                options = SHOW_MODES.map { it.first },
                selected = viewMode,
                label = { labels[it] ?: "" },
                onSelect = { vm.setViewMode(it) },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        PanelChevron("«", { vm.setLeftPanel(false) }, Modifier.padding(6.dp))
    }
}

private val SHOW_MODES = listOf(
    FrameViewMode.VIEW_ORIGINAL to "original frame",
    FrameViewMode.VIEW_PROCESSED to "final processed frame",
    FrameViewMode.VIEW_SUBTRACTION to "subtracted frame",
    FrameViewMode.VIEW_VALIDATION to "validation data",
)
