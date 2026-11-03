package com.star.desktop.ui.sequence

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.dp
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.FrameState
import com.star.desktop.domain.SavingCounts
import com.star.desktop.i18n.localized
import com.star.desktop.ui.theme.StarColors

/**
 * The edit view's read-outs under the frame (macOS `BottomRightView`): how many frames are waiting to be written after an edit, what the
 * frame being looked at is doing, what is still loading for it, and how many of its outlier groups will be removed, kept, undecided or
 * are in the trash. Each shows only when there is something to say.
 */
@Composable
fun BottomStatus(vm: SequenceViewModel) {
    val current by vm.currentIndex.collectAsState()
    val fvm = remember(current) { vm.frameVMFor(current) }
    val savingStages by vm.savingState.collectAsState()
    val states by vm.frameStates.collectAsState()
    val info by fvm.info.collectAsState()
    val loading by fvm.loading.collectAsState()
    val loadingTrash by fvm.loadingTrash.collectAsState()

    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        // Edited frames on their way to disk: in purgatory (waiting for more edits), queued, being written.
        val saving = remember(savingStages) { SavingCounts.of(savingStages) }
        if (saving.any) {
            Column(horizontalAlignment = Alignment.End) {
                if (saving.purgatory > 0) Line(localized("ui.n_frames_in_purgatory", saving.purgatory), StarColors.purple)
                if (saving.waiting > 0) Line(localized("ui.n_frames_waiting_to_save", saving.waiting), StarColors.yellow)
                if (saving.saving > 0) Line(localized("ui.saving_n_frames", saving.saving), StarColors.green)
            }
        }

        states[current]?.let { Line(localized("ui.frame_is_state", FrameState.message(it)), StarColors.stateColor(it), "status.state") }

        if (loading || loadingTrash) {
            Column {
                if (loading) Line(localized("ui.loading_outlier_views"), StarColors.green)
                if (loadingTrash) Line(localized("ui.loading_outlier_trash_views"), StarColors.orange)
            }
        }

        // Counts are only the frame's once its outliers have been read; before that they are zeroes that mean nothing.
        // They only apply to frames that use outliers: selective, or automatic with auto-select.
        info?.takeIf { it.outliersLoaded && it.cleanMethod != com.star.proto.CleanMethod.CLEAN_AUTOMATIC }?.let { i ->
            Column {
                Line(localized("ui.n_will_remove", i.numPositiveOutliers), if (i.numPositiveOutliers == 0) StarColors.white else StarColors.red, "status.remove")
                Line(localized("ui.n_will_keep", i.numNegativeOutliers), if (i.numNegativeOutliers == 0) StarColors.white else StarColors.green, "status.keep")
                if (i.numUndecidedOutliers > 0) Line(localized("ui.n_undecided", i.numUndecidedOutliers), StarColors.orange)
                if (i.numTrashOutliers > 0) Line(localized("ui.n_in_trash", i.numTrashOutliers), StarColors.yellow)
            }
        }
    }
}

@Composable
private fun Line(text: String, color: androidx.compose.ui.graphics.Color, tag: String? = null) {
    Text(text, color = color, fontSize = 11.sp, modifier = tag?.let { Modifier.testTag(it) } ?: Modifier)
}
