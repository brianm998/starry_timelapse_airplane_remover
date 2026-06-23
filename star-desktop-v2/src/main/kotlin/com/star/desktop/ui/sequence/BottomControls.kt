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
import com.star.desktop.ui.components.GlyphButton
import com.star.desktop.ui.theme.StarColors

/** Bottom transport bar: playback buttons, editable frame number, fps, filmstrip toggle. */
@Composable
fun BottomControls(vm: SequenceViewModel, modifier: Modifier = Modifier) {
    val idx by vm.currentIndex.collectAsState()
    val playing by vm.isPlaying.collectAsState()
    val fps by vm.playbackFps.collectAsState()
    val showFilmstrip by vm.showFilmstrip.collectAsState()

    Row(
        modifier = modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        // transport — 8 buttons when stopped; collapses to just play/pause while playing (macOS)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            if (playing) {
                GlyphButton("⏸", "Pause", vm::togglePlayback, size = 40, fontSize = 24, tint = StarColors.blue)
            } else {
                val atStart = idx <= 0
                val atEnd = idx >= vm.frameCount - 1
                val multi = vm.frameCount > 1
                GlyphButton("⏮", "Go to first frame (b)", vm::goToFirst, enabled = !atStart)
                GlyphButton("⏪", "Back 20 frames (z)", vm::fastPrevious, enabled = !atStart)
                GlyphButton("◂", "Previous frame (←)", vm::previous, enabled = !atStart, fontSize = 13)
                GlyphButton("◀", "Play in reverse (w)", vm::playReverse, enabled = multi, size = 40, fontSize = 20)
                GlyphButton("▶", "Play (space)", vm::playForward, enabled = multi, size = 40, fontSize = 20)
                GlyphButton("▸", "Next frame (→)", vm::next, enabled = !atEnd, fontSize = 13)
                GlyphButton("⏩", "Forward 20 frames (x)", vm::fastForward, enabled = !atEnd)
                GlyphButton("⏭", "Go to last frame (f)", vm::goToLast, enabled = !atEnd)
            }
        }

        // editable frame number
        EditableFrameNumber(idx, vm.frameCount, onSet = vm::setCurrentIndex)

        // fps + filmstrip toggle
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("fps", color = StarColors.textDisabled, fontSize = 10.sp)
            GlyphButton("−", "Slower", { vm.setPlaybackFps(fps - 1) }, size = 22, fontSize = 14)
            Text("$fps", color = StarColors.textSecondary, fontSize = 12.sp, modifier = Modifier.width(24.dp))
            GlyphButton("+", "Faster", { vm.setPlaybackFps(fps + 1) }, size = 22, fontSize = 14)
            GlyphButton(if (showFilmstrip) "▥" else "▤", "Toggle filmstrip", vm::toggleFilmstrip, size = 26, fontSize = 14)
        }
    }
}

/** Editable "current / total" frame number (macOS `EditableFrameNumberView`). */
@Composable
private fun EditableFrameNumber(index: Int, count: Int, onSet: (Int) -> Unit) {
    var editing by remember { mutableStateOf(false) }
    var text by remember(index) { mutableStateOf((index + 1).toString()) }

    Row(verticalAlignment = Alignment.CenterVertically) {
        if (editing) {
            BasicTextField(
                value = text,
                onValueChange = { text = it.filter(Char::isDigit) },
                singleLine = true,
                textStyle = TextStyle(color = StarColors.textPrimary, fontSize = 13.sp),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = {
                    text.toIntOrNull()?.let { onSet(it - 1) }
                    editing = false
                }),
                modifier = Modifier.width(40.dp).background(StarColors.sidePanel),
            )
            Text(" / $count", color = StarColors.textSecondary, fontSize = 13.sp)
        } else {
            Box(Modifier.padding(horizontal = 6.dp)) {
                androidx.compose.material3.Surface(
                    onClick = { editing = true; text = (index + 1).toString() },
                    color = androidx.compose.ui.graphics.Color.Transparent,
                ) {
                    Text(
                        buildAnnotatedString {
                            withStyle(SpanStyle(color = StarColors.textPrimary)) { append("${index + 1}") }
                            withStyle(SpanStyle(color = StarColors.textDisabled)) { append(" / $count") }
                        },
                        fontSize = 13.sp,
                    )
                }
            }
        }
    }
}
