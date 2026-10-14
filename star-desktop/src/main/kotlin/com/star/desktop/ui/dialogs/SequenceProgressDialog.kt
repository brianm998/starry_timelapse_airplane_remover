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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.ReopenVerdict
import com.star.desktop.domain.StepRow
import com.star.desktop.i18n.localized
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.components.HoverTip
import com.star.desktop.ui.components.defaultAction
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.SequenceProgress

/**
 * What is put up when a sequence is reopened from its config (macOS `SequenceProgressPanel`): which sequence it is, how far the last run got
 * (a verdict, "N / M frames complete", and one bar per step surveyed from the disk), and the one thing left to do about it: render the video if
 * every frame is written, start or finish the processing if not. Like the macOS panel it is modal (a click outside does nothing) and
 * Return takes the action.
 */
@Composable
fun SequenceProgressDialog(app: AppViewModel, progress: SequenceProgress) {
    val verdict = ReopenVerdict.of(progress)
    val action = if (verdict.rendersVideo) app::renderVideoForOpenedSequence else app::finishProcessingOpenedSequence

    Box(
        Modifier
            .fillMaxSize()
            .background(StarColors.scrim)
            .defaultAction(action, onEscape = app::closeSequenceProgress)
            .clickable(enabled = false) {},
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .widthIn(min = 480.dp, max = 640.dp)
                .padding(20.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard),
        ) {
            // Which sequence this is, then how far it got: two pairs, so the caption under each line reads as belonging to it.
            Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(localized("ui.where_this_sequence_left_off"), color = StarColors.white, fontSize = 18.sp)
                    // The sequence's own name, because Open Recent is a list of paths and it is entirely possible to have opened the wrong one.
                    Text(progress.sequenceName, color = StarColors.textSecondary, fontSize = 11.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        localized(verdict.statusKey),
                        color = if (verdict == ReopenVerdict.COMPLETE) StarColors.green else StarColors.white, fontSize = 13.sp,
                    )
                    Text(
                        localized("progress.frames_complete", progress.framesComplete, progress.frameCount),
                        color = StarColors.textSecondary, fontSize = 11.sp,
                    )
                }
            }
            HorizontalDivider(color = StarColors.cellDefault)

            Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(20.dp)) {
                StepsView(StepRow.of(progress.stepsList), hasReport = true)
            }

            HorizontalDivider(color = StarColors.cellDefault)
            Row(Modifier.fillMaxWidth().padding(20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                HoverTip(localized("ui.close_this_and_go_to_the_frames")) {
                    OutlinedButton(onClick = app::closeSequenceProgress) { Text(localized("ui.close")) }
                }
                Box(Modifier.weight(1f))
                HoverTip(localized(verdict.actionHelpKey)) {
                    Button(onClick = action, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) {
                        Text(localized(verdict.actionKey), fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
}
