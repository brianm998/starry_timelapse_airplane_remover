package com.star.desktop.ui.dialogs

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameStateCounts
import com.star.desktop.domain.ProcessingHeadline
import com.star.desktop.domain.StepRateTracker
import com.star.desktop.domain.StepRow
import com.star.desktop.i18n.localized
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.components.AlignmentInfoButton
import com.star.desktop.ui.components.AlignmentInfoOverlay
import com.star.desktop.ui.components.DeviationChart
import com.star.desktop.ui.components.HoverTip
import com.star.desktop.ui.sequence.SequenceViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes

private val NAME_WIDTH = 180.dp
private val NUMBER_WIDTH = 46.dp
/** The time-left column between each bar and its counts. */
private val ETA_WIDTH = 56.dp
/** For what is finished or has nothing left: quieter than the white of what is live. */
private val SETTLED = Color(0.68f, 0.68f, 0.68f)
private val COUNT_WIDTH = NUMBER_WIDTH * 3

/**
 * Processing progress screen (macOS `ProcessingModalView`): what each step of the run is doing, in one bar each (done, running, still
 * queued) with "N of M complete" and what the step is on hover, how many frames are finished, how much of this Mac the run may use,
 * a Stop (cancels the run) and a Dismiss that only hides this screen: the run keeps going, so the user can look at the frames that are done.
 */
@Composable
fun ProcessingModal(app: AppViewModel, svm: SequenceViewModel) {
    val frameStates by svm.frameStates.collectAsState()
    val report by svm.stepProgress.collectAsState()
    val rows = StepRow.of(report)
    val counts = FrameStateCounts(frameStates, svm.frameCount)
    val extraction by svm.extraction.collectAsState()
    // Fed each time the counts change; not state the screen draws, so updating it asks for no further pass.
    val rates = remember { StepRateTracker() }
    rates.observe(rows)
    val headline = ProcessingHeadline.text(rows, extraction, report != null, counts.complete, svm.frameCount)
    val overall = ProcessingHeadline.overallText(rows) { rates.secondsRemaining(it) }
    val estimates = rows.mapNotNull { row -> rates.secondsRemaining(row)?.let { row.type to it } }.toMap()
    val session by app.sessions.session.collectAsState()
    val cameraMoving = session?.config?.tripodHeadWasMoving == true
    var showingInfo by remember { mutableStateOf(false) }

    Box(Modifier.fillMaxSize().background(StarColors.scrim).clickable(enabled = false) {}, contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .widthIn(min = 480.dp, max = 640.dp)
                .padding(20.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard),
        ) {
            // The header: a spinner, what the run is doing (the status line while there is one, else how many frames are done), and the
            // control for how much of the machine it may use, which takes effect on the run as it goes.
            Row(Modifier.fillMaxWidth().padding(20.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                CircularProgressIndicator(Modifier.size(20.dp), color = StarColors.white, strokeWidth = 2.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(localized("ui.processing_frames"), color = StarColors.white, fontSize = 18.sp)
                    Text(
                        report?.status?.takeIf { it.isNotEmpty() } ?: localized("progress.frames_complete", counts.complete, svm.frameCount),
                        color = StarColors.textSecondary, fontSize = 12.sp,
                    )
                    if (overall != null) Text(overall, color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 12.sp, modifier = Modifier.testTag("processing.overall"))
                    if (headline != null) Text(headline, color = StarColors.white.copy(alpha = 0.85f), fontSize = 12.sp, modifier = Modifier.testTag("processing.headline"))
                }
                ResourceProfileControl(app)
            }
            HorizontalDivider(color = StarColors.cellDefault)

            Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                StepsView(rows, hasReport = report != null, extraction = extraction, estimates = estimates)
                HorizontalDivider(color = StarColors.cellDefault)
                AlignmentSection(app, svm) { showingInfo = true }
            }

            HorizontalDivider(color = StarColors.cellDefault)
            Row(Modifier.fillMaxWidth().padding(20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                HoverTip(localized("ui.cancel_all_pending_processing_operations")) {
                    Text(
                        localized("ui.stop_processing"),
                        color = Color.White, fontSize = 13.sp,
                        modifier = Modifier
                            .clip(RoundedCornerShape(6.dp))
                            .background(Color.Red.copy(alpha = 0.8f))
                            .clickable { svm.cancelProcessing() }
                            .padding(horizontal = 10.dp, vertical = 5.dp),
                    )
                }
                Box(Modifier.weight(1f))
                Text(localized("ui.preview_while_processing_help"), color = StarColors.white.copy(alpha = 0.7f), fontSize = 11.sp, modifier = Modifier.widthIn(max = 320.dp))
                Button(onClick = svm::dismissProcessingModal, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) {
                    Text(localized("ui.preview"))
                }
            }
        }
        if (showingInfo) AlignmentInfoOverlay(cameraMoving) { showingInfo = false }
    }
}

/** One bar per processing step, stacked in the order the daemon sends them (also drawn by the reopened-sequence panel, over what was found on disk). */
@Composable
internal fun StepsView(rows: List<StepRow>, hasReport: Boolean, extraction: com.star.proto.FrameExtraction? = null, estimates: Map<String, Double> = emptyMap()) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(localized("ui.steps"), color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
        // Extracting the video's frames comes first, above the horizon, for frames that are being extracted from a video.
        if (extraction != null && extraction.active) ExtractionRowView(extraction)
        when {
            // Nothing reported yet: the run is still being planned.
            !hasReport -> Text("…", color = StarColors.textSecondary, fontSize = 12.sp)
            // Every step turned out to have nothing left to do (a re-run over a sequence that is already finished).
            rows.isEmpty() -> Text(localized("ui.nothing_to_do"), color = StarColors.textSecondary, fontSize = 12.sp)
            else -> {
                // Done above, Processing beneath it, each heading only while it has rows: a finishing step moves from one list to the other.
                val (done, processing) = rows.partition { it.isDone }
                if (done.isNotEmpty()) {
                    GroupHeader(localized("ui.done"), showsCounts = true)
                    done.forEach { StepRowView(it, isDone = true, estimates[it.type]) }
                }
                if (processing.isNotEmpty()) {
                    GroupHeader(localized("ui.processing"), showsCounts = done.isEmpty())
                    processing.forEach { StepRowView(it, isDone = false, estimates[it.type]) }
                }
            }
        }
    }
}

/** A sub-label over a group of rows; the first one on screen also names the three number columns, which line up with every row below. */
@Composable
private fun GroupHeader(title: String, showsCounts: Boolean) {
    Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, color = StarColors.textSecondary, fontSize = 12.sp, modifier = Modifier.weight(1f))
        if (showsCounts) {
            EtaColumn(localized("ui.time_left"), StarColors.textSecondary)
            CountColumns(localized("ui.queued"), localized("ui.running"), localized("ui.done"), List(3) { StarColors.textSecondary })
        }
    }
}

/** The queued, running and done columns. */
@Composable
private fun CountColumns(queued: String, running: String, done: String, colors: List<Color>) {
    Row {
        for ((index, text) in listOf(queued, running, done).withIndex()) {
            Text(text, color = colors[index], fontSize = 12.sp, maxLines = 1, textAlign = androidx.compose.ui.text.style.TextAlign.End, modifier = Modifier.width(NUMBER_WIDTH))
        }
    }
}

/** The time left for a step, in the column beside its bar; empty until there is a rate to go on. */
@Composable
private fun EtaColumn(text: String, color: Color = Color.White) {
    Text(text, color = color, fontSize = 12.sp, maxLines = 1, textAlign = androidx.compose.ui.text.style.TextAlign.End, modifier = Modifier.width(ETA_WIDTH))
}

private fun etaText(seconds: Double?): String = if (seconds == null || !seconds.isFinite()) "" else ProcessingHeadline.duration(seconds)

@Composable
private fun ExtractionRowView(e: com.star.proto.FrameExtraction) {
    val name = localized("ui.processing_step_extracting_video")
    HoverTip(name) {
        Row(Modifier.fillMaxWidth().testTag("processing.extraction"), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(name, color = StarColors.white, fontSize = 13.sp, maxLines = 2, modifier = Modifier.width(NAME_WIDTH))
            val done = if (e.total > 0) (e.extracted.toFloat() / e.total).coerceIn(0f, 1f) else 0f
            Row(Modifier.weight(1f).height(14.dp).clip(RoundedCornerShape(4.dp)).background(Color(0.32f, 0.32f, 0.32f))) {
                if (done > 0f) Box(Modifier.weight(done).fillMaxHeight().background(StarColors.green))
                if (done < 1f) Box(Modifier.weight(1f - done).fillMaxHeight())
            }
            EtaColumn(if (e.complete || !e.etaKnown) "" else etaText(e.etaSeconds))
            Text(
                localized("ui.n_of_m_complete", e.extracted, e.total),
                color = StarColors.white, fontSize = 12.sp, maxLines = 2,
                textAlign = androidx.compose.ui.text.style.TextAlign.End, modifier = Modifier.width(COUNT_WIDTH),
            )
        }
    }
}

@Composable
private fun StepRowView(step: StepRow, isDone: Boolean, secondsLeft: Double?) {
    HoverTip(step.help) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(step.name, color = if (!step.hasWork) StarColors.textSecondary else if (isDone) SETTLED else StarColors.white, fontSize = 13.sp, maxLines = 2, modifier = Modifier.width(NAME_WIDTH))
            StepBar(step, Modifier.weight(1f))
            EtaColumn(if (isDone) "" else etaText(secondsLeft))
            // A step with no operations is only on screen while the plan is still being worked out, so this says "not known yet".
            // A column goes quiet when it has nothing to say: nothing queued, nothing running, or everything done.
            if (step.hasWork) CountColumns(
                "${step.queued}", "${step.running}", "${step.completed}",
                listOf(
                    if (step.queued == 0) SETTLED else StarColors.white,
                    if (step.running == 0) SETTLED else StarColors.white,
                    if (step.completed == step.total) SETTLED else StarColors.white,
                ),
            )
            else Text("—", color = StarColors.textSecondary, fontSize = 12.sp, textAlign = androidx.compose.ui.text.style.TextAlign.End, modifier = Modifier.width(COUNT_WIDTH))
        }
    }
}

/** Done, then running, then what is still queued as the track behind them: the same three colours as the left panel's progress bar. */
@Composable
private fun StepBar(step: StepRow, modifier: Modifier = Modifier) {
    Row(modifier.height(14.dp).clip(RoundedCornerShape(4.dp)).background(Color(0.32f, 0.32f, 0.32f))) {
        if (step.doneFraction > 0f) Box(Modifier.weight(step.doneFraction).fillMaxHeight().background(StarColors.green))
        if (step.runningFraction > 0f) Box(Modifier.weight(step.runningFraction).fillMaxHeight().background(StarColors.yellow))
        val rest = 1f - step.doneFraction - step.runningFraction
        if (rest > 0f) Box(Modifier.weight(rest).fillMaxHeight())
    }
}

/** "Use of this Mac": Full, Balanced, Light, or Custom (whose limits are in the settings). Changing it reaches a run in progress. */
@Composable
private fun ResourceProfileControl(app: AppViewModel) {
    val session by app.sessions.session.collectAsState()
    val current = session?.config?.takeIf { it.hasResourceProfile() }?.resourceProfile ?: "full"
    Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        HoverTip(localized("ui.use_of_this_mac_help")) {
            Text(localized("ui.use_of_this_mac"), color = StarColors.textSecondary, fontSize = 11.sp)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            for ((profile, key) in listOf("full" to "ui.use_full", "balanced" to "ui.use_balanced", "light" to "ui.use_light", "custom" to "ui.use_custom")) {
                val selected = current == profile
                Text(
                    localized(key),
                    color = if (selected) Color.White else StarColors.textPrimary, fontSize = 11.sp,
                    modifier = Modifier
                        .clip(RoundedCornerShape(5.dp))
                        .background(if (selected) StarColors.accent else StarColors.cellDefault)
                        .clickable { app.setResourceProfile(profile) }
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                )
            }
        }
    }
}

/**
 * The alignment charts the run is producing (macOS `ProcessingModalPanel`'s alignment section): the star deviation chart, and the earth one
 * when earth alignment is on, filling in as frames align, with a "waiting" line in their place until the first result lands so the panel does
 * not jump. The checkbox hides them, which makes the panel shorter on a small window; it is kept in the preferences, since this screen is
 * rebuilt every time it is dismissed and brought back.
 */
@Composable
private fun AlignmentSection(app: AppViewModel, svm: SequenceViewModel, showInfo: () -> Unit) {
    var show by remember { mutableStateOf(app.prefs.showAlignmentInProcessingWindow) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(localized("ui.alignment_2"), color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            AlignmentInfoButton(showInfo)
            HoverTip(localized("ui.open_alignment_window_help")) {
                Text("↗", color = StarColors.textSecondary, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 4.dp).clickable { app.openAlignmentWindow() })
            }
            Box(Modifier.weight(1f))
            HoverTip(localized("ui.show_alignment_results_help")) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = show, onCheckedChange = { show = it; app.prefs.showAlignmentInProcessingWindow = it })
                    Text(localized("ui.show_alignment_results"), color = StarColors.textSecondary, fontSize = 11.sp)
                }
            }
        }
        if (show) AlignmentCharts(svm)
    }
}

@Composable
private fun AlignmentCharts(svm: SequenceViewModel) {
    val data by svm.alignment.collectAsState()
    val current by svm.currentIndex.collectAsState()
    val alignment = data
    if (alignment != null && alignment.hasStar) {
        Text(localized("ui.deviation_in_star_alignment"), color = StarColors.textSecondary, fontSize = 11.sp)
        DeviationChart(alignment.starPoints, svm.frameCount, current, svm::setCurrentIndex, chartHeight = 220.dp)
        if (alignment.allowEarth && alignment.hasEarth) {
            Text(localized("ui.deviation_in_earth_alignment"), color = StarColors.textSecondary, fontSize = 11.sp)
            DeviationChart(alignment.earthPoints, svm.frameCount, current, svm::setCurrentIndex, chartHeight = 220.dp)
        }
    } else {
        // Nothing has aligned yet. An empty chart reads as a failure rather than as a step that has not run, so say which it is.
        Box(Modifier.fillMaxWidth().height(220.dp), contentAlignment = Alignment.Center) {
            Text(localized("ui.waiting_for_alignment_data"), color = StarColors.textSecondary, fontSize = 13.sp)
        }
    }
}
