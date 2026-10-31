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
import androidx.compose.ui.platform.testTag
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

/** Bottom transport bar: playback buttons, editable frame number, filmstrip toggle. */
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun BottomControls(app: com.star.desktop.ui.app.AppViewModel, vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val idx by vm.currentIndex.collectAsState()
    val playing by vm.isPlaying.collectAsState()
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
        // "[edit] with [original] frames" at the left, as the gui has it; not there while the sequence plays.
        if (!playing) ModeAndViewPickers(vm, mode)

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

        // Process / Show Progress and Render Video, which used to sit at the top of the left panel; the left panel is the edit view's.
        if (mode == com.star.desktop.domain.InteractionMode.EDIT) ProcessingButtons(app, vm)

        // What a run is doing, with its Stop, in every mode; scrub and grid hide it while playing (macOS: nothing else competes then).
        if (mode == com.star.desktop.domain.InteractionMode.EDIT || !playing) ProcessingStatus(vm, mode)
        // The rest of the read-outs are the edit view's: what the frame is doing, its outlier counts, and what is being saved.
        if (mode == com.star.desktop.domain.InteractionMode.EDIT) BottomStatus(vm)

        // The frame number is not shown while playing (macOS), when it would only blur past.
        if (!playing) EditableFrameNumber(idx, vm.frameCount, onSet = vm::setCurrentIndex)

        // filmstrip toggle (the playback speed is the Display section's picker, as in the gui)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            GlyphButton(if (showFilmstrip) "▥" else "▤", localized("ui.toggle_filmstrip"), vm::toggleFilmstrip, size = 26, fontSize = 14)
            if (mode == com.star.desktop.domain.InteractionMode.EDIT) {
                com.star.desktop.ui.components.HoverTip(localized("ui.show_settings")) {
                    GlyphButton("⚙", localized("ui.show_settings"), app::openSettings, size = 26, fontSize = 16)
                }
            }
        }
    }
}

/** The label on the view picker's two choices (the gui's `BottomLeftView.viewLabel`, the same two keys). */
fun viewPickerLabel(mode: com.star.proto.FrameViewMode): String =
    localized(if (mode == com.star.proto.FrameViewMode.VIEW_PROCESSED) "ui.view_processed" else "ui.view_original")

/** The two images the picker chooses between (the gui's picker lists the original and the final frame and no other). */
val VIEW_PICKER_MODES = listOf(com.star.proto.FrameViewMode.VIEW_ORIGINAL, com.star.proto.FrameViewMode.VIEW_PROCESSED)

/**
 * The mode picker, "with", the view picker and "frames" (macOS `BottomLeftView`), which sat in the top bar. A choice the frame has no
 * image of is greyed out and does nothing; one it can build (an aligned image, Q3) counts as having it.
 */
@Composable
private fun ModeAndViewPickers(vm: SequenceViewModel, mode: com.star.desktop.domain.InteractionMode) {
    val viewMode by vm.viewMode.collectAsState()
    val current by vm.currentIndex.collectAsState()
    val states by vm.frameStates.collectAsState()
    // The images the frame has, fetched again when the frame or what it is doing changes.
    var available by remember { mutableStateOf(setOf(com.star.proto.FrameViewMode.VIEW_ORIGINAL)) }
    LaunchedEffect(current, states[current]) { available = vm.availableViewModes(current).toSet() }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        HoverTip(localized("ui.interaction_mode_help")) {
            com.star.desktop.ui.components.StarPicker(
                options = com.star.desktop.domain.InteractionMode.entries,
                selected = mode,
                label = { localized(it.labelKey) },
                onSelect = { vm.setMode(it) },
            )
        }
        Text(localized("ui.with"), color = StarColors.textPrimary, fontSize = 13.sp)
        com.star.desktop.ui.components.StarPicker(
            options = VIEW_PICKER_MODES,
            selected = viewMode, // grid 'Show' may set SUBTRACTION/VALIDATION → no pill highlights (matches old chips)
            label = ::viewPickerLabel,
            onSelect = { vm.setViewMode(it) },
            isEnabled = { it in available },
        )
        Text(localized("ui.frames"), color = StarColors.textPrimary, fontSize = 13.sp)
    }
}

/**
 * "Process Frames" / "Show Progress" and "Render Video" (macOS `ProcessingButtonsView`). The first is one button in two roles: while a
 * run is going it puts the processing screen back, otherwise it opens the settings, where a run is started. Render is on screen only
 * once processing is complete, since there is nothing to render a video from before that, and the first button gives its place up to it.
 */
@Composable
private fun ProcessingButtons(app: com.star.desktop.ui.app.AppViewModel, vm: SequenceViewModel) {
    val processing by vm.isProcessing.collectAsState()
    val rendering by vm.rendering.collectAsState()
    val states by vm.frameStates.collectAsState()
    val refinementPending by vm.refinementPending.collectAsState()
    val total = vm.frameCount
    val counts = remember(states, total) { com.star.desktop.domain.FrameStateCounts(states, total) }
    val role = com.star.desktop.domain.ProcessingButtonRole.current(processing, rendering, counts, total, refinementPending)
    val layout = com.star.desktop.domain.ProcessingButtonsLayout.current(processing, rendering, counts.complete, total, refinementPending)
    val colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = StarColors.accent)

    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (layout.showsProcess) {
            when (role) {
                com.star.desktop.domain.ProcessingButtonRole.Status -> HoverTip(localized("ui.show_the_processing_status_again")) {
                    androidx.compose.material3.Button(onClick = { vm.reopenProcessingModal() }, colors = colors) { Text(localized("ui.show_progress")) }
                }
                is com.star.desktop.domain.ProcessingButtonRole.Process -> HoverTip(localized("ui.choose_settings_and_process_these_frames")) {
                    androidx.compose.material3.Button(
                        onClick = { app.openSettings() },
                        enabled = role.enabled,
                        colors = colors,
                        modifier = Modifier.testTag("process.frames"),
                    ) { Text(localized("ui.process_frames")) }
                }
            }
        }
        if (layout.showsRender) {
            androidx.compose.material3.Button(
                onClick = { app.openRenderVideo() },
                enabled = layout.renderEnabled,
                colors = colors,
            ) { Text(localized("ui.render_video")) }
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
