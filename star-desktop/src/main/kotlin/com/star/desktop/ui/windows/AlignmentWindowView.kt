package com.star.desktop.ui.windows

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.AlignmentCharts
import com.star.desktop.i18n.localized
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.components.DeviationChart
import com.star.desktop.ui.components.KeypointChart
import com.star.desktop.ui.components.OffsetLegend
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors

/**
 * Alignment diagnostics window (macOS `AlignmentWindowView`): how far each frame's alignment to its neighbors moved the picture (one line per
 * neighbor offset, with the warps the heuristics distrust in red) and how many keypoints each frame had, for the sky and, when earth alignment
 * is on, the ground. It keeps up with a run as it goes; the checkboxes pick which of the charts show, and the legend names the lines that do.
 * See [com.star.desktop.ui.components.DeviationChart] for what the pointer does on a chart.
 */
@Composable
fun AlignmentWindowView(@Suppress("UNUSED_PARAMETER") app: AppViewModel, svm: SequenceViewModel) {
    val data by svm.alignment.collectAsState()
    val current by svm.currentIndex.collectAsState()
    val count = svm.frameCount

    var showStarDeviation by remember { mutableStateOf(true) }
    var showStarKeypoints by remember { mutableStateOf(true) }
    var showEarthDeviation by remember { mutableStateOf(true) }
    var showEarthKeypoints by remember { mutableStateOf(true) }

    val alignment = data
    Row(Modifier.fillMaxSize().background(StarColors.appBackground).padding(20.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        if (alignment == null || !(alignment.hasStar || alignment.hasEarth)) {
            Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) {
                Text(
                    localized(if (alignment == null) "ui.waiting_for_alignment_data" else "ui.no_alignment_data_process_the_sequence_first"),
                    color = StarColors.textDisabled, fontSize = 12.sp,
                )
            }
            return@Row
        }
        val earthShowing = alignment.allowEarth && alignment.hasEarth

        Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            if (alignment.hasStar) {
                if (showStarDeviation) {
                    ChartTitle(localized("ui.deviation_in_star_alignment"))
                    DeviationChart(alignment.starPoints, count, current, svm::setCurrentIndex)
                }
                if (showStarKeypoints) {
                    ChartTitle(localized("ui.star_keypoints"))
                    KeypointChart(alignment.skyKeypoints, count, current, svm::setCurrentIndex)
                }
            }
            if (earthShowing) {
                if (showEarthDeviation) {
                    ChartTitle(localized("ui.deviation_in_earth_alignment"))
                    DeviationChart(alignment.earthPoints, count, current, svm::setCurrentIndex)
                }
                if (showEarthKeypoints) {
                    ChartTitle(localized("ui.earth_keypoints"))
                    KeypointChart(alignment.earthKeypoints, count, current, svm::setCurrentIndex)
                }
            }
        }

        // Which charts show, then the legend of the lines on the ones that do.
        Column(Modifier.width(190.dp).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(localized("ui.show_2"), color = StarColors.textPrimary, fontSize = 13.sp, modifier = Modifier.padding(top = 4.dp, bottom = 4.dp))
            Toggle(localized("ui.star_deviation"), showStarDeviation) { showStarDeviation = it }
            Toggle(localized("ui.star_keypoints"), showStarKeypoints) { showStarKeypoints = it }
            if (alignment.allowEarth) {
                Toggle(localized("ui.earth_deviation"), showEarthDeviation) { showEarthDeviation = it }
                Toggle(localized("ui.earth_keypoints"), showEarthKeypoints) { showEarthKeypoints = it }
            }
            HorizontalDivider(Modifier.padding(vertical = 8.dp), color = StarColors.cellDefault)
            Text(localized("ui.legend"), color = StarColors.textPrimary, fontSize = 13.sp, modifier = Modifier.padding(bottom = 4.dp))
            // The offsets of the series that are showing (keypoints share the star and earth readings' neighbors).
            val offsets = AlignmentCharts.visibleOffsets(
                if (showStarDeviation || showStarKeypoints) alignment.starPoints else emptyList(),
                if (alignment.allowEarth && (showEarthDeviation || showEarthKeypoints)) alignment.earthPoints else emptyList(),
            )
            Column(Modifier.verticalScroll(rememberScrollState())) { OffsetLegend(offsets) }
        }
    }
}

@Composable
private fun ChartTitle(text: String) {
    Text(text, color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
}

@Composable
private fun Toggle(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        Checkbox(checked = checked, onCheckedChange = onChange)
        Text(label, color = StarColors.textPrimary, fontSize = 12.sp)
    }
}
