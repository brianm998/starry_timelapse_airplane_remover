package com.star.desktop.ui.windows

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Switch
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.domain.BlobStepFormat
import com.star.desktop.i18n.localized
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.BlobStep
import com.star.proto.BlobStepArg
import com.star.proto.DetectionType

/** The types in the order macOS lists them, the custom one last. */
private val DETECTION_TYPES = listOf(
    DetectionType.DETECTION_MILD, DetectionType.DETECTION_STRONG, DetectionType.DETECTION_STRONGER,
    DetectionType.DETECTION_EXCESSIVE, DetectionType.DETECTION_CUSTOM,
)

private fun typeName(type: DetectionType): String = localized("detection_type." + type.name.removePrefix("DETECTION_").lowercase())

/**
 * The Blob Processing window (macOS `BlobProcessingView`, a developer tool): the steps a detection type takes each frame's blobs through, with what
 * each does and the parameters it takes. The custom type is the one that can be changed: its parameters are edited in place (Return, or leaving the
 * box, sets one), a step with parameters can be skipped, and it can be made a copy of another type to start from. [session] is false when no sequence
 * is open, as in the Mac app, where there is nothing to show then.
 */
@Composable
fun BlobProcessingWindowView(session: Boolean, current: DetectionType, onSelectType: (DetectionType) -> Unit, model: BlobProcessingModel) {
    Column(Modifier.fillMaxSize().background(StarColors.appBackground).padding(16.dp)) {
        if (!session) {
            Text(localized("ui.no_image_sequence_loaded"), color = StarColors.textPrimary, fontSize = 14.sp)
            Text(localized("ui.load_an_image_sequence_in_the_main_star_2"), color = StarColors.textSecondary, fontSize = 12.sp)
            return@Column
        }
        // what is on show follows the session's type, and is asked for again when it changes
        LaunchedEffect(current) { model.load(current) }
        val response by model.steps.collectAsState()
        val error by model.error.collectAsState()
        val shown = response?.takeIf { it.detectionType == current }
        val editable = shown?.editable == true

        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(localized("ui.blob_processing_steps"), color = StarColors.textPrimary, fontSize = 20.sp)
            TypePicker(localized("ui.current_detection_type"), current, DETECTION_TYPES, onSelectType)
            shown?.description?.let { Text(it, color = StarColors.textSecondary, fontSize = 12.sp) }
            error?.let { Text(it, color = StarColors.red, fontSize = 12.sp) }

            if (editable) {
                if (shown?.stepsCount == 0) {
                    Text(localized("ui.you_have_loaded_an_empty_set_of_steps"), color = StarColors.textPrimary, fontSize = 16.sp)
                }
                TypePicker(localized("ui.please_choose_an_existing_detection_type_to"), null, DETECTION_TYPES.filter { it != DetectionType.DETECTION_CUSTOM }, model::copyFrom)
            }

            if (shown != null && !(editable && shown.stepsCount == 0)) {
                Card {
                    Text(localized("ui.setup"), color = StarColors.textPrimary, fontSize = 18.sp)
                    for (key in listOf(
                        "ui.to_begin_processing_each_frame_we_must_first", "ui.create_a_star_aligned_image", "ui.subtract_the_star_aligned_image_from_the",
                        "ui.both_of_these_can_be_loaded_from_file_if", "ui.there_are_no_configurable_parameters_here",
                    )) Text(localized(key), color = StarColors.textSecondary, fontSize = 12.sp)
                }
                shown.stepsList.forEachIndexed { index, step -> StepCard(index, step, editable, model) }
                Card {
                    Text(localized("ui.blob_processing_complete"), color = StarColors.textPrimary, fontSize = 18.sp)
                    Text(localized("ui.blob_processing_complete_desc"), color = StarColors.textSecondary, fontSize = 12.sp)
                }
            }
        }
    }
}

@Composable
private fun Card(content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxWidth().clip(StarShapes.card).background(StarColors.cellDefault).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) { content() }
}

/** One step: its title and what it does; for a step with parameters the table of them, with a switch to skip it on the custom type. */
@Composable
private fun StepCard(index: Int, step: BlobStep, editable: Boolean, model: BlobProcessingModel) {
    Card {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (editable && step.canDisable) {
                Text(localized("ui.disable"), color = StarColors.textSecondary, fontSize = 12.sp)
                Switch(checked = step.disabled, onCheckedChange = { model.setDisabled(index, it) })
            }
            Text(step.title, color = StarColors.textPrimary, fontSize = 18.sp)
            // a step with nothing to configure says what it carries beside its title
            if (step.argsCount == 0) Text(step.description, color = StarColors.textSecondary, fontSize = 12.sp)
        }
        if (step.argsCount > 0) {
            Text(step.description, color = StarColors.textSecondary, fontSize = 12.sp)
            Text(localized("ui.parameters_which_can_affect_how_this_step"), color = StarColors.textSecondary, fontSize = 12.sp)
            Column(Modifier.alpha(if (step.disabled) 0.5f else 1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    HeaderCell(localized("ui.name"), 200)
                    HeaderCell(localized("ui.value"), 90)
                    Text(localized("ui.description"), color = StarColors.textPrimary, fontSize = 12.sp, modifier = Modifier.weight(1f))
                }
                step.argsList.forEach { arg -> ArgRow(index, arg, editable && !step.disabled, model) }
            }
        }
    }
}

@Composable
private fun HeaderCell(text: String, width: Int) = Text(text, color = StarColors.textPrimary, fontSize = 12.sp, modifier = Modifier.width(width.dp))

@Composable
private fun ArgRow(stepIndex: Int, arg: BlobStepArg, editable: Boolean, model: BlobProcessingModel) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
        Text(arg.name, color = StarColors.textSecondary, fontSize = 12.sp, modifier = Modifier.width(200.dp))
        Box(Modifier.width(90.dp)) {
            val shown = if (arg.valuePresent) BlobStepFormat.show(arg.value, arg.isInteger) else ""
            if (editable) {
                ValueField(shown, arg.isInteger) { model.setArg(stepIndex, arg.name, it) }
            } else {
                Text(shown, color = StarColors.textSecondary, fontSize = 12.sp)
            }
        }
        Text(arg.description, color = StarColors.textSecondary, fontSize = 12.sp, modifier = Modifier.weight(1f))
    }
}

/** A number to edit: set on Return or on leaving the box; text that is not a number (or not a whole one, for an integer) is put back. */
@Composable
private fun ValueField(shown: String, isInteger: Boolean, onSet: (Double) -> Unit) {
    var text by remember(shown) { mutableStateOf(shown) }
    fun commit() {
        val value = BlobStepFormat.parse(text, isInteger)
        if (value == null) text = shown else if (text != shown) onSet(value)
    }
    BasicTextField(
        value = text,
        onValueChange = { text = it },
        singleLine = true,
        textStyle = TextStyle(color = StarColors.white, fontSize = 12.sp),
        cursorBrush = SolidColor(StarColors.white),
        modifier = Modifier
            .width(80.dp)
            .background(StarColors.sidePanel)
            .padding(horizontal = 6.dp, vertical = 4.dp)
            .onFocusChanged { if (!it.isFocused) commit() }
            .onPreviewKeyEvent { e ->
                if (e.type == KeyEventType.KeyDown && (e.key == Key.Enter || e.key == Key.NumPadEnter)) { commit(); true } else false
            },
    )
}

/** A label and a menu of detection types; [selected] is null for a menu that only offers a choice (copy from). */
@Composable
private fun TypePicker(label: String, selected: DetectionType?, options: List<DetectionType>, onSelect: (DetectionType) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, color = StarColors.textSecondary, fontSize = 12.sp)
        Box {
            Box(
                Modifier.clip(StarShapes.picker).background(StarColors.cellDefault).clickable { expanded = true }.padding(horizontal = 10.dp, vertical = 6.dp),
            ) {
                Text(selected?.let { typeName(it) } ?: "…", color = StarColors.textPrimary, fontSize = 12.sp)
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                options.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(typeName(option), color = if (option == selected) StarColors.accent else StarColors.textPrimary, fontSize = 12.sp) },
                        onClick = { onSelect(option); expanded = false },
                    )
                }
            }
        }
    }
}
