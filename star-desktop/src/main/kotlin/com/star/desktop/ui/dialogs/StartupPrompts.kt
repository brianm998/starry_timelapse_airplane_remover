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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.app.StartupStep
import com.star.desktop.ui.app.suggestedMovingHorizonCount
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
    Title("Does this video include a horizon?")
    AnswerRow(advanced = { app.startupOpenAdvanced() }) {
        SecondaryButton("No") { app.startupAnswerHorizon(false) }
        PrimaryButton("Yes") { app.startupAnswerHorizon(true) }
    }
}

@Composable
private fun MovingPrompt(app: AppViewModel) {
    Title("Was the camera moving during this video")
    Title("or", small = true)
    Title("was it stationary on a tripod the entire time?")
    AnswerRow(advanced = { app.startupOpenAdvanced() }) {
        SecondaryButton("Static") { app.startupAnswerMoving(false) }
        PrimaryButton("Moving") { app.startupAnswerMoving(true) }
    }
}

@Composable
private fun SelectHorizonPrompt(app: AppViewModel) {
    Title("Do you want to select the horizon yourself?")
    Body(
        "Star lets you tell it where the horizon is. If you spend a minute or two selecting and " +
            "refining the horizon yourself now, you will speed up Star's processing and avoid horizon-" +
            "detection errors.",
    )
    AnswerRow {
        SecondaryButton("No") { app.startupAnswerSelectHorizon(false) }
        PrimaryButton("Yes") { app.startupAnswerSelectHorizon(true) }
    }
}

/**
 * Moving-video variant (macOS `SelectMovingHorizonsView`): the user picks how many evenly-spaced
 * frames to paint a horizon for. "Yes" steps through each in the painter; "No" goes to removal.
 */
@Composable
private fun SelectMovingHorizonsPrompt(app: AppViewModel) {
    val maxCount = app.startupFrameCount()
    var count by remember { mutableStateOf(suggestedMovingHorizonCount(maxCount)) }

    Title("Do you want to select the horizons yourself?")
    Body(
        "Star lets you tell it where the horizon is for specific frames of this moving video. If you " +
            "define horizons on evenly-spaced frames now, you will speed up Star's processing and avoid " +
            "horizon-detection errors. Star will use these painted frames as references for all frames in " +
            "the sequence.",
    )
    Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Spacer(Modifier.weight(1f))
        SecondaryButton("No") { app.startupAnswerSelectHorizon(false) }
        Spacer(Modifier.width(28.dp))
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Stepper("Define $count ${horizonWord(count)}", count, 1, maxCount) { count = it }
            PrimaryButton("Yes, select $count ${horizonWord(count)}") { app.startMovingHorizonStartupFlow(count) }
        }
        Spacer(Modifier.weight(1f))
    }
}

private fun horizonWord(count: Int) = if (count == 1) "horizon" else "horizons"

@Composable
private fun RemovalPrompt(app: AppViewModel) {
    var airplanes by remember { mutableStateOf(true) }
    var satellites by remember { mutableStateOf(true) }
    var meteors by remember { mutableStateOf(true) }
    val cleanMethod = removalCleanMethod(airplanes, satellites, meteors)

    Title("What do you want Star to remove?")
    Body(
        "Star can remove some or all of these from this video. The choice here is the default for all " +
            "frames, and can later be changed frame by frame.",
    )
    HorizontalDivider(color = StarColors.cellDefault)
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(localized("ui.star_should_remove"), color = StarColors.textPrimary, fontSize = 15.sp)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            ToggleRow("Airplanes", airplanes) { airplanes = it }
            ToggleRow("Satellites", satellites) { satellites = it }
            ToggleRow("Meteors", meteors) { meteors = it }
        }
    }
    HorizontalDivider(color = StarColors.cellDefault)
    Body(removalDescription(cleanMethod))
    AnswerRow(advanced = { app.startupOpenAdvanced() }) {
        SecondaryButton("Close") { app.dismissStartup() }
        PrimaryButton("Start Processing") { app.startupStartProcessing(cleanMethod) }
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

/** Centered answer buttons, with an optional "Advanced" gear pinned to the right (macOS layout). */
@Composable
private fun AnswerRow(advanced: (() -> Unit)? = null, buttons: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(top = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { buttons() }
        Spacer(Modifier.weight(1f))
        if (advanced != null) AdvancedButton(advanced)
    }
}

@Composable
private fun PrimaryButton(text: String, onClick: () -> Unit) {
    Button(onClick = onClick, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) {
        Text(text, color = Color.White)
    }
}

@Composable
private fun SecondaryButton(text: String, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick) { Text(text) }
}

@Composable
private fun AdvancedButton(onClick: () -> Unit) {
    Column(
        Modifier.clip(StarShapes.card).clickable(onClick = onClick).padding(horizontal = 8.dp, vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("⚙", color = StarColors.textSecondary, fontSize = 30.sp)
        Text(localized("ui.advanced"), color = StarColors.textSecondary, fontSize = 11.sp)
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
private fun ToggleRow(label: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Switch(checked = value, onCheckedChange = onChange)
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

private fun removalDescription(method: CleanMethod): String = when (method) {
    CleanMethod.CLEAN_AUTOMATIC ->
        "Star will run in automatic mode, replacing all bad pixels. If everything goes well it will " +
            "not require any per-frame attention."
    CleanMethod.CLEAN_AUTOMATIC_TRUE ->
        "Star will run in auto mode, replacing all bad pixels, then do further processing so you can " +
            "select removed pixels to return to their original state. Star cannot yet tell airplanes, " +
            "satellites and meteors apart, so you will review each frame."
    else ->
        "Star will run in selective mode, analyzing each frame for bad signals and trying to categorize " +
            "them automatically. The initial results may need some frame-by-frame attention."
}
