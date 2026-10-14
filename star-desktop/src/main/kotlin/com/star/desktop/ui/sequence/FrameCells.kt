package com.star.desktop.ui.sequence

import androidx.compose.foundation.ContextMenuItem
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerKeyboardModifiers
import androidx.compose.ui.input.pointer.isCtrlPressed
import androidx.compose.ui.input.pointer.isMetaPressed
import androidx.compose.ui.input.pointer.isShiftPressed
import androidx.compose.ui.input.pointer.onPointerEvent
import com.star.desktop.i18n.localized
import com.star.proto.ReprocessingType

/**
 * What clicking a frame's cell does, in the filmstrip and the grid alike (macOS `handleTap`): Shift selects the frames from the current one
 * to this one, Ctrl or Cmd adds this one to the selection or takes it out, and a plain click goes to it and selects it alone.
 * [onDoubleClick] is the grid's, which opens the frame.
 */
@OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class)
@Composable
fun Modifier.frameCellClicks(vm: SequenceViewModel, index: Int, onDoubleClick: (() -> Unit)? = null): Modifier {
    var mods by remember { mutableStateOf<PointerKeyboardModifiers?>(null) }
    return this
        .onPointerEvent(PointerEventType.Press) { mods = it.keyboardModifiers }
        .combinedClickable(
            onClick = {
                val m = mods
                when {
                    m?.isShiftPressed == true -> vm.select(index, range = true)
                    m?.isCtrlPressed == true || m?.isMetaPressed == true -> vm.select(index, additive = true)
                    else -> vm.select(index)
                }
            },
            onDoubleClick = onDoubleClick,
        )
}

/**
 * The right-click menu of a frame's cell (macOS `filmstripContextMenu`): how many frames it acts on (the whole selection, or this one),
 * and the ways to process them again, from the gentlest to throwing everything away. Empty for a cell that is not selected: the menu
 * is about the selection, and a frame outside it would be acted on by a menu that does not say so.
 */
fun frameCellMenu(vm: SequenceViewModel, cellIsSelected: Boolean, selectedCount: Int): List<ContextMenuItem> {
    if (!cellIsSelected) return emptyList()
    val label = if (selectedCount <= 1) localized("ui.one_frame") else localized("ui.n_frames_capitalised", selectedCount)
    return listOf(
        ContextMenuItem(label) { },                       // the header: says what the items below act on
        ContextMenuItem(localized("ui.process_n_new_only", label)) { vm.reprocessSelected(ReprocessingType.REPROCESS_NONE) },
        ContextMenuItem(localized("ui.re_process_alignment")) { vm.reprocessSelected(ReprocessingType.REPROCESS_ALIGNMENT) },
        ContextMenuItem(localized("ui.re_process_outliers")) { vm.reprocessSelected(ReprocessingType.REPROCESS_OUTLIERS) },
        ContextMenuItem(localized("ui.re_process_horizons")) { vm.reprocessSelected(ReprocessingType.REPROCESS_HORIZONS) },
        ContextMenuItem(localized("ui.re_process_everything")) { vm.reprocessSelected(ReprocessingType.REPROCESS_EVERYTHING) },
    )
}
