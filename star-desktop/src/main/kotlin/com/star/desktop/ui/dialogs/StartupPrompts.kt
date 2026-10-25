package com.star.desktop.ui.dialogs

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Checkbox
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import com.star.desktop.domain.KeypointDivisor
import com.star.desktop.ui.components.HoverTip
import com.star.proto.KeypointDivisorAdvice
import kotlin.math.abs
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.app.StartupStep
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.proto.CleanMethod
import com.star.desktop.i18n.localized

/**
 * New-source startup prompts (macOS `StartupView`): a small state machine asking about the
 * sequence (horizon? camera moving? paint horizon yourself? what to remove?) before processing.
 * Each prompt also exposes an "Advanced" gear that jumps straight to the full Processing Settings.
 */
@Composable
fun StartupPrompts(app: AppViewModel, step: StartupStep) {
    StartupCard {
        when (step) {
            StartupStep.HORIZON -> HorizonPrompt(app)
            StartupStep.MOVING -> MovingPrompt(app)
            StartupStep.SELECT_HORIZON -> SelectHorizonPrompt(app)
            StartupStep.SELECT_MOVING_HORIZONS -> SelectMovingHorizonsPrompt(app)
            StartupStep.REMOVAL -> RemovalPrompt(app)
        }
    }
}

@Composable
private fun StartupCard(content: @Composable () -> Unit) {
    // Modal: no scrim-dismiss — the user answers (or hits "Advanced"/"Close" on the removal step).
    Box(Modifier.fillMaxSize().background(StarColors.scrim), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .widthIn(min = 420.dp, max = 600.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .verticalScroll(rememberScrollState())
                .padding(28.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) { content() }
    }
}

@Composable
private fun HorizonPrompt(app: AppViewModel) {
    Title(localized("ui.does_this_video_include_a_horizon"))
    AnswerRow(advanced = { app.startupOpenAdvanced() }) {
        SecondaryButton(localized("ui.no"), "startup.horizon.no") { app.startupAnswerHorizon(false) }
        PrimaryButton(localized("ui.yes"), "startup.horizon.yes") { app.startupAnswerHorizon(true) }
    }
}

@Composable
private fun MovingPrompt(app: AppViewModel) {
    Title(localized("ui.was_the_camera_moving_during_this_video"))
    Title(localized("ui.or"), small = true)
    Title(localized("ui.was_it_stationary_on_a_tripod_the_entire"))
    AnswerRow(back = { app.startupGoBack(StartupStep.MOVING) }, advanced = { app.startupOpenAdvanced() }) {
        SecondaryButton(localized("ui.static"), "startup.moving.static") { app.startupAnswerMoving(false) }
        PrimaryButton(localized("ui.moving"), "startup.moving.moving") { app.startupAnswerMoving(true) }
    }
}

@Composable
private fun SelectHorizonPrompt(app: AppViewModel) {
    Title(localized("ui.do_you_want_to_select_the_horizon_yourself"))
    Body(localized("ui.star_allows_you_to_tell_it_where_the_horizon"))
    AnswerRow(back = { app.startupGoBack(StartupStep.SELECT_HORIZON) }) {
        SecondaryButton(localized("ui.no"), "startup.selecthorizon.no") { app.startupAnswerSelectHorizon(false) }
        PrimaryButton(localized("ui.yes"), "startup.selecthorizon.yes") { app.startupAnswerSelectHorizon(true) }
    }
}

/**
 * Moving-video variant (macOS `SelectMovingHorizonsView`): the user picks how many evenly-spaced
 * frames to paint a horizon for. "Yes" steps through each in the painter; "No" goes to removal.
 */
@Composable
private fun SelectMovingHorizonsPrompt(app: AppViewModel) {
    val maxCount = app.startupFrameCount()
    var count by remember { mutableStateOf(app.preferredHorizonCount()) }

    Title(localized("ui.do_you_want_to_select_the_horizons_yourself"))
    Body(localized("ui.star_allows_you_to_tell_it_where_the_horizon_2"))
    Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        BackButton { app.startupGoBack(StartupStep.SELECT_MOVING_HORIZONS) }
        Spacer(Modifier.weight(1f))
        SecondaryButton(localized("ui.no"), "startup.selectmovinghorizons.no") { app.startupAnswerSelectHorizon(false) }
        Spacer(Modifier.width(28.dp))
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            // every step records the preference: only a user change reaches this callback
            Stepper(localized(if (count == 1) "ui.define_n_horizons_one" else "ui.define_n_horizons", count), count, 1, maxCount) {
                count = it
                app.recordHorizonCount(it)
            }
            PrimaryButton(localized(if (count == 1) "ui.select_n_horizons_one" else "ui.select_n_horizons", count)) { app.startMovingHorizonStartupFlow(count) }
        }
        Spacer(Modifier.weight(1f))
    }
}

@Composable
private fun RemovalPrompt(app: AppViewModel) {
    var airplanes by remember { mutableStateOf(true) }
    var satellites by remember { mutableStateOf(true) }
    var meteors by remember { mutableStateOf(true) }
    var cars by remember { mutableStateOf(true) }
    val cleanMethod = removalCleanMethod(airplanes, satellites, meteors)

    Title(localized("ui.what_do_you_want_star_to_remove"))
    Body(localized("ui.star_can_remove_some_or_all_of_these_things"))
    HorizontalDivider(color = StarColors.cellDefault)
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(localized("ui.star_should_remove"), color = StarColors.textPrimary, fontSize = 15.sp)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            ToggleRow(localized("ui.airplanes"), airplanes, "startup.removal.airplanes") { airplanes = it }
            ToggleRow(localized("ui.satellites"), satellites, "startup.removal.satellites") { satellites = it }
            ToggleRow(localized("ui.meteors"), meteors, "startup.removal.meteors") { meteors = it }
            ToggleRow(localized("ui.cars"), cars, "startup.removal.cars") { cars = it }
        }
    }
    HorizontalDivider(color = StarColors.cellDefault)
    Body(removalDescription(cleanMethod))
    HorizontalDivider(color = StarColors.cellDefault)
    KeypointDivisorSection(app)
    HorizontalDivider(color = StarColors.cellDefault)
    AnswerRow(back = { app.startupGoBack(StartupStep.REMOVAL) }, advanced = { app.startupOpenAdvanced() }) {
        SecondaryButton(localized("ui.close")) { app.dismissStartup() }
        PrimaryButton(localized("ui.start_processing"), "startup.removal.start") { app.startupStartProcessing(cleanMethod, allowEarthAlignment = cars) }
    }
}

/**
 * "Speed vs. Sharpness" (macOS `KeypointDivisorStartupView`): how much smaller than the frame the alignment step looks for stars, which on a
 * large sequence decides whether the run goes at a sensible speed or crawls. Collapsed to its title when this machine copes with the
 * sequence at full resolution, open when it does not or when a value was already set. The choice is written as it is made (see
 * [AppViewModel.setKeypointDivisor]), so what is typed counts without being committed.
 */
@Composable
private fun KeypointDivisorSection(app: AppViewModel) {
    val session by app.sessions.session.collectAsState()
    val divisor = session?.config?.alignmentKeypointDetectionDivisor?.takeIf { it > 0.0 } ?: 1.0
    var advice by remember { mutableStateOf<KeypointDivisorAdvice?>(null) }
    var expanded by remember { mutableStateOf(false) }
    var customText by remember { mutableStateOf(KeypointDivisor.format(divisor)) }
    var customFocused by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        val answer = app.keypointAdvice()
        advice = answer
        expanded = KeypointDivisor.initiallyExpanded(answer, app.sessions.session.value?.config?.alignmentKeypointDetectionDivisor ?: 1.0)
    }
    // Follow the value when a preset moved it, but never while the field is being typed into: that would rewrite the text under the cursor.
    LaunchedEffect(divisor) { if (!customFocused) customText = KeypointDivisor.format(divisor) }

    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        HoverTip(localized(if (expanded) "ui.hide_speed_settings" else "ui.show_speed_settings")) {
            Row(
                Modifier.fillMaxWidth().clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(if (expanded) "▼" else "▶", color = StarColors.textSecondary, fontSize = 13.sp)
                Text(localized("ui.speed_vs_sharpness"), color = StarColors.textPrimary, fontSize = 18.sp)
                if (!expanded) {
                    Text(localized("ui.current_choice_suffix", KeypointDivisor.currentChoiceName(divisor)), color = StarColors.textSecondary, fontSize = 15.sp)
                }
            }
        }
        if (expanded) {
            Body(KeypointDivisor.explanation(advice))
            for (preset in KeypointDivisor.presets) {
                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Checkbox(
                            checked = KeypointDivisor.matches(divisor, preset.divisor),
                            // Exclusive: checking one selects it, and unchecking the checked one does nothing.
                            onCheckedChange = { if (it) app.setKeypointDivisor(preset.divisor) },
                        )
                        Text(localized(preset.nameKey), color = StarColors.textPrimary, fontSize = 15.sp)
                        Text(KeypointDivisor.format(preset.divisor), color = StarColors.textDisabled, fontSize = 15.sp)
                        if (KeypointDivisor.isRecommended(advice, preset.divisor)) {
                            Text(
                                localized("ui.recommended"), color = Color.White, fontSize = 11.sp,
                                modifier = Modifier.clip(RoundedCornerShape(50)).background(StarColors.accent.copy(alpha = 0.7f)).padding(horizontal = 6.dp, vertical = 1.dp),
                            )
                        }
                    }
                    Text(localized(preset.blurbKey), color = StarColors.textSecondary, fontSize = 11.sp, modifier = Modifier.padding(start = 42.dp))
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(localized("ui.or_use"), color = StarColors.textSecondary, fontSize = 15.sp)
                BasicTextField(
                    value = customText,
                    onValueChange = { text ->
                        customText = text
                        // Applied on every keystroke: every prefix of a number being typed is itself a number.
                        KeypointDivisor.parse(text)?.let { if (abs(it - divisor) >= 0.0001) app.setKeypointDivisor(it) }
                    },
                    singleLine = true,
                    textStyle = TextStyle(color = StarColors.white, fontSize = 13.sp),
                    cursorBrush = SolidColor(StarColors.white),
                    modifier = Modifier
                        .width(70.dp)
                        .background(StarColors.sidePanel)
                        .padding(horizontal = 6.dp, vertical = 4.dp)
                        .onFocusChanged { customFocused = it.isFocused },
                )
                Text(localized("ui.any_number_from_1_to_8_1_is_full_size_2_is"), color = StarColors.textDisabled, fontSize = 11.sp)
            }
            if (KeypointDivisor.isTooHigh(divisor)) {
                Text(localized("ui.keypoint_too_high", KeypointDivisor.format(divisor)), color = StarColors.yellow, fontSize = 13.sp)
            }
        }
    }
}

// ---- shared pieces ----

@Composable
private fun Title(text: String, small: Boolean = false) {
    Text(
        text,
        color = StarColors.textPrimary,
        fontWeight = FontWeight.SemiBold,
        fontSize = if (small) 18.sp else 22.sp,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun Body(text: String) {
    Text(text, color = StarColors.textSecondary, fontSize = 13.sp, modifier = Modifier.fillMaxWidth())
}

/**
 * Centered answer buttons, with an optional "Back" pinned to the left and an optional
 * "Advanced" gear pinned to the right (macOS layout).
 */
@Composable
private fun AnswerRow(back: (() -> Unit)? = null, advanced: (() -> Unit)? = null, buttons: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(top = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (back != null) BackButton(back)
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { buttons() }
        Spacer(Modifier.weight(1f))
        if (advanced != null) AdvancedButton(advanced)
    }
}

/**
 * Subdued "go to the previous question" control, shown on every startup screen after the first
 * (macOS `StartupBackButton`). Lets the user correct an earlier answer without restarting.
 */
@Composable
private fun BackButton(onClick: () -> Unit) {
    Row(
        Modifier.clip(StarShapes.card).clickable(onClick = onClick).padding(horizontal = 4.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text("‹", color = StarColors.textPrimary, fontSize = 20.sp)
        Text(localized("ui.back"), color = StarColors.textPrimary, fontSize = 15.sp)
    }
}

@Composable
private fun PrimaryButton(text: String, tag: String? = null, onClick: () -> Unit) {
    Button(onClick = onClick, modifier = tag?.let { Modifier.testTag(it) } ?: Modifier, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) {
        Text(text, color = Color.White)
    }
}

@Composable
private fun SecondaryButton(text: String, tag: String? = null, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, modifier = tag?.let { Modifier.testTag(it) } ?: Modifier) { Text(text) }
}

@Composable
private fun AdvancedButton(onClick: () -> Unit) {
    HoverTip(localized("ui.show_advanced_settings")) {
        Column(
            Modifier.clip(StarShapes.card).clickable(onClick = onClick).padding(horizontal = 8.dp, vertical = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("⚙", color = StarColors.textSecondary, fontSize = 30.sp)
            Text(localized("ui.advanced"), color = StarColors.textSecondary, fontSize = 11.sp)
        }
    }
}

/** Minus/value/plus count control (macOS `Stepper`), clamped to [min]..[max]. */
@Composable
private fun Stepper(label: String, value: Int, min: Int, max: Int, onChange: (Int) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(label, color = StarColors.textPrimary, fontSize = 16.sp)
        OutlinedButton(onClick = { onChange(value - 1) }, enabled = value > min) { Text("−") }
        OutlinedButton(onClick = { onChange(value + 1) }, enabled = value < max) { Text("+") }
    }
}

@Composable
private fun ToggleRow(label: String, value: Boolean, tag: String, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Switch(checked = value, onCheckedChange = onChange, modifier = Modifier.testTag(tag))
        Text(label, color = StarColors.textPrimary, fontSize = 14.sp)
    }
}

// ---- removal → clean-method mapping (macOS RemovalView.cleanMethod) ----

/**
 * Maps the three removal toggles to a clean method, matching macOS `RemovalView`:
 * remove everything → automatic (no outliers); any partial selection that keeps outlier review
 * → auto-selective; airplane-centric / nothing → selective.
 */
private fun removalCleanMethod(airplanes: Boolean, satellites: Boolean, meteors: Boolean): CleanMethod = when {
    airplanes && satellites && meteors -> CleanMethod.CLEAN_AUTOMATIC      // remove all
    airplanes && satellites && !meteors -> CleanMethod.CLEAN_AUTOMATIC_TRUE
    airplanes && !satellites -> CleanMethod.CLEAN_SELECTIVE                // airplanes (± meteors)
    !airplanes && !satellites && !meteors -> CleanMethod.CLEAN_SELECTIVE   // nothing
    else -> CleanMethod.CLEAN_AUTOMATIC_TRUE                               // satellite/meteor-centric
}

private fun removalDescription(method: CleanMethod): String = localized(
    when (method) {
        CleanMethod.CLEAN_AUTOMATIC -> "ui.mode_desc_automatic"
        CleanMethod.CLEAN_AUTOMATIC_TRUE -> "ui.mode_desc_auto_selective"
        else -> "ui.mode_desc_selective"
    },
)
