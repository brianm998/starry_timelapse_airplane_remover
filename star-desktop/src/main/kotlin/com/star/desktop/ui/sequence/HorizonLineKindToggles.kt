package com.star.desktop.ui.sequence

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Checkbox
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.components.HorizonLineKinds
import com.star.desktop.ui.components.horizonLineColor
import com.star.desktop.ui.theme.StarColors
import com.star.proto.HorizonOverlayKind

/**
 * One show/hide switch per kind of horizon line, under the "show horizon lines" switch (macOS `HorizonLineKindToggles`).  A kind
 * the current frame has no line of is greyed out, as is every kind while the lines are hidden.
 */
@Composable
fun HorizonLineKindToggles(vm: SequenceViewModel) {
    val current by vm.currentIndex.collectAsState()
    val showHorizon by vm.showHorizonOnMainView.collectAsState()
    val visible by vm.visibleHorizonLineKinds.collectAsState()
    val horizonVersion by vm.horizonVersion.collectAsState()
    val frameStates by vm.frameStates.collectAsState()
    var available by remember(current) { mutableStateOf<Set<HorizonOverlayKind>>(emptySet()) }
    // Only which kinds the frame has is wanted here, so a narrow overlay is enough.
    LaunchedEffect(current, horizonVersion, frameStates[current]) {
        available = HorizonLineKinds.available(runCatching { vm.horizonOverlay(current, 16, 16) }.getOrNull())
    }
    Column(verticalArrangement = Arrangement.spacedBy(0.dp), modifier = Modifier.padding(start = 16.dp)) {
        for (kind in HorizonLineKinds.all) {
            val enabled = showHorizon && kind in available
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.alpha(if (enabled) 1f else 0.4f)) {
                Checkbox(
                    checked = kind in visible,
                    onCheckedChange = { vm.setHorizonLineKindVisible(kind, it) },
                    enabled = enabled,
                )
                Spacer(Modifier.size(8.dp).background(horizonLineColor(kind, pending = false), CircleShape))
                Spacer(Modifier.width(6.dp))
                Text(HorizonLineKinds.label(kind), color = StarColors.white, fontSize = 11.sp)
            }
        }
    }
}
