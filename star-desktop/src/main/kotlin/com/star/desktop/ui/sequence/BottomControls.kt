package com.star.desktop.ui.sequence

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import com.star.desktop.domain.FrameNumberInput
import com.star.desktop.ui.components.GlyphButton
import com.star.desktop.ui.components.HoverTip
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.i18n.localized

/** Bottom transport bar: playback buttons, editable frame number, fps, filmstrip toggle. */
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun BottomControls(app: com.star.desktop.ui.app.AppViewModel, vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val idx by vm.currentIndex.collectAsState()
    val playing by vm.isPlaying.collectAsState()
    val fps by vm.playbackFps.collectAsState()
    val showFilmstrip by vm.showFilmstrip.collectAsState()
    val mode by vm.mode.collectAsState()
    val skip by vm.fastSkipAmount.collectAsState()
    val selected by vm.selected.collectAsState()

    // Wraps onto a second and third row when the window is too narrow for all of it (macOS lays it out in rows).
    androidx.compose.foundation.layout.FlowRow(
        modifier = modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        // transport — 8 buttons when stopped; collapses to just play/pause while playing (macOS)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            if (playing) {
                GlyphButton("⏸", localized("ui.transport_pause"), vm::togglePlayback, size = 40, fontSize = 24, tint = StarColors.blue)
            } else {
                // With several frames selected the arrows go round them, so there is no start or end to be at.
                val atStart = idx <= 0 && selected.size <= 1
                val atEnd = idx >= vm.frameCount - 1 && selected.size <= 1
                val multi = vm.frameCount > 1
                GlyphButton("⏮", localized("ui.transport_first_frame"), vm::goToFirst, enabled = !atStart)
                GlyphButton("⏪", localized("ui.transport_back_frames", skip), vm::fastPrevious, enabled = !atStart)
                GlyphButton("◂", localized("ui.transport_previous_frame"), vm::previous, enabled = !atStart, fontSize = 13)
                GlyphButton("◀", localized("ui.transport_play_reverse"), vm::playReverse, enabled = multi, size = 40, fontSize = 20)
                GlyphButton("▶", localized("ui.transport_play"), vm::playForward, enabled = multi, size = 40, fontSize = 20)
                GlyphButton("▸", localized("ui.transport_next_frame"), vm::next, enabled = !atEnd, fontSize = 13)
                GlyphButton("⏩", localized("ui.transport_forward_frames", skip), vm::fastForward, enabled = !atEnd)
                GlyphButton("⏭", localized("ui.transport_last_frame"), vm::goToLast, enabled = !atEnd)
            }
        }

        // What a run is doing, with its Stop, in every mode; scrub and grid hide it while playing (macOS: nothing else competes then).
        if (mode == com.star.desktop.domain.InteractionMode.EDIT || !playing) ProcessingStatus(vm, mode)
        // The rest of the read-outs are the edit view's: what the frame is doing, its outlier counts, and what is being saved.
        if (mode == com.star.desktop.domain.InteractionMode.EDIT) BottomStatus(vm)

        // The frame number is not shown while playing (macOS), when it would only blur past.
        if (!playing) EditableFrameNumber(idx, vm.frameCount, onSet = vm::setCurrentIndex)

        // fps + filmstrip toggle
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(localized("ui.fps"), color = StarColors.textDisabled, fontSize = 10.sp)
            GlyphButton("−", localized("ui.transport_slower"), { vm.setPlaybackFps(fps - 1) }, size = 22, fontSize = 14)
            Text("$fps", color = StarColors.textSecondary, fontSize = 12.sp, modifier = Modifier.width(24.dp))
            GlyphButton("+", localized("ui.transport_faster"), { vm.setPlaybackFps(fps + 1) }, size = 22, fontSize = 14)
            GlyphButton(if (showFilmstrip) "▥" else "▤", localized("ui.toggle_filmstrip"), vm::toggleFilmstrip, size = 26, fontSize = 14)
            if (mode == com.star.desktop.domain.InteractionMode.EDIT) {
                com.star.desktop.ui.components.HoverTip(localized("ui.show_settings")) {
                    GlyphButton("⚙", localized("ui.show_settings"), app::openSettings, size = 26, fontSize = 16)
                }
            }
        }
    }
}

/**
 * The frame number (macOS `EditableFrameNumberView`): "frame N", from 0 like every frame number in the app, and a click turns it into
 * a box to type another in. Return goes there if it names a frame; an entry out of range is refused, not clamped, and leaves the box
 * open; Escape or leaving the box puts it back.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
private fun EditableFrameNumber(index: Int, count: Int, onSet: (Int) -> Unit) {
    var editing by remember { mutableStateOf(false) }
    var text by remember(index, editing) { mutableStateOf(index.toString()) }
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }

    if (editing) {
        LaunchedEffect(Unit) { focus.requestFocus() }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(localized("ui.frame_2"), color = StarColors.white, fontSize = 13.sp)
            BasicTextField(
                value = text,
                onValueChange = { text = it.filter(Char::isDigit) },
                singleLine = true,
                textStyle = TextStyle(color = StarColors.white, fontSize = 13.sp),
                cursorBrush = androidx.compose.ui.graphics.SolidColor(StarColors.white),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
                modifier = Modifier
                    .width(48.dp)
                    .background(StarColors.sidePanel)
                    .padding(horizontal = 4.dp, vertical = 2.dp)
                    .focusRequester(focus)
                    .onFocusChanged { if (!it.isFocused) editing = false }
                    .onPreviewKeyEvent { e ->
                        if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                        when (e.key) {
                            Key.Enter, Key.NumPadEnter -> {
                                FrameNumberInput.parse(text, count)?.let { onSet(it); editing = false }
                                true
                            }
                            Key.Escape -> { editing = false; true }
                            else -> false
                        }
                    },
            )
        }
    } else {
        HoverTip(localized("ui.n_frames_lower", count)) {
            Text(
                localized("ui.frame_n_lower", index),
                color = StarColors.white,
                fontSize = 13.sp,
                modifier = Modifier.clickable { editing = true }.padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
    }
}
