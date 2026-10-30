package com.star.desktop.ui.dialogs

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.components.modalScrim
import com.star.desktop.ui.components.defaultAction
import com.star.desktop.domain.RenderState
import com.star.desktop.domain.RenderVideo
import com.star.desktop.i18n.localized
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.desktop.util.FileReveal
import com.star.proto.VideoCapabilities
import com.star.proto.VideoEncodeSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Render Video sheet (macOS `RenderVideoSheetView`): cascading pickers driven by `Export.GetVideoCapabilities` (codec → encoder → pixel format and
 * container, plus frame rate, any rate if Custom), each with what it is, how long the video comes out, and what it will be called; then the
 * render, with its progress and a Cancel; then where the video went, with a button that shows it in the file manager; or why it failed.
 *
 * Which of those it is, is the app's ([AppViewModel.renderState]), so that closing the window can ask whether a render is going. Clicking
 * outside during a render does nothing; Cancel is the way to stop one.
 */
@Composable
fun RenderVideoDialog(app: AppViewModel) {
    val caps by produceState<VideoCapabilities?>(null) { value = runCatching { app.export.capabilities() }.getOrNull() }
    val state by app.renderState.collectAsState()
    val rendering = state is RenderState.Rendering

    Box(
        // Esc closes it, except while a render is going (its own Cancel is what stops that); a click outside the card does not.
        Modifier.fillMaxSize().background(StarColors.scrim).modalScrim()
            .defaultAction({}, onEscape = { if (!rendering) app.closeRenderVideo() }),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 560.dp)
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            when (val s = state) {
                is RenderState.Rendering -> RenderingView(s, onCancel = app::cancelRender)
                is RenderState.Succeeded -> SucceededView(s, onDismiss = app::closeRenderVideo)
                is RenderState.Failed -> FailedView(s, onDismiss = app::closeRenderVideo)
                RenderState.Choosing -> {
                    val c = caps
                    if (c == null) {
                        Text(localized("ui.render_video"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                        Text(localized("ui.loading_codecs"), color = StarColors.textSecondary, fontSize = 13.sp)
                    } else {
                        ChoiceView(app, c)
                    }
                }
            }
        }
    }
}

/** The pickers, with what each choice is, and the Cancel and Render buttons. */
@Composable
private fun ChoiceView(app: AppViewModel, c: VideoCapabilities) {
    val info = app.sessions.session.value
    val frameCount = info?.frameCount ?: 0

    // Start from what the config holds (an import's own settings are there), not the first entry of every list, as the gui does (L12); each
    // level is checked against what the one above allows.
    val start = remember(c) { storedVideoSettings(info) }
    var choice by remember(c) { mutableStateOf(resolveVideoChoice(c, start)) }
    /** A choice the user made: kept in the Mac's preferences, which the macOS gui seeds a new sequence from; this client starts from the config. */
    fun choose(next: VideoChoice) {
        choice = next
        app.prefs.videoFrameRate = next.frameRate
        app.prefs.videoCodec = next.codec.takeIf { it.isNotEmpty() }
        app.prefs.videoEncoder = next.encoder.takeIf { it.isNotEmpty() }
        app.prefs.videoPixelFormat = next.pixelFormat.takeIf { it.isNotEmpty() }
        app.prefs.videoMuxer = next.muxer.takeIf { it.isNotEmpty() }
    }

    val codecs = c.codecsList
    val codecCaps = codecs.firstOrNull { it.codec == choice.codec }
    val encoders = codecCaps?.encodersList.orEmpty()
    val encCaps = encoders.firstOrNull { it.encoder == choice.encoder }
    val pixelFormats = encCaps?.pixelFormatsList.orEmpty()
    val muxers = encCaps?.muxersList.orEmpty()
    val pixelCaps = encCaps?.pixelFormatCapsList?.firstOrNull { it.name == choice.pixelFormat }
    val muxerCaps = encCaps?.muxerCapsList?.firstOrNull { it.name == choice.muxer }
    // Whether Custom is the picked entry.  Not derivable from the rate: Custom starts at the current rate, which is usually a standard one, and
    // looking the entry up by rate would read that as the standard entry again and put the picker (and the field) back.
    var customPicked by remember(c) { mutableStateOf(RenderVideo.rateEntry(c, choice.frameRate)?.custom == true) }
    val rateEntry = RenderVideo.shownRateEntry(c, choice.frameRate, customPicked)

    Text(localized("ui.render_video_from_n_frames", frameCount), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)

    // Frame rate: a standard one, or Custom with a field for any rate up to 1000.
    val rateOptions = c.frameRateCapsList.map { (if (it.custom) "custom" else RenderVideo.rateText(it.value)) to (if (it.custom) localized("ui.custom_2") else RenderVideo.rateText(it.value)) }
    val rateKey = if (rateEntry?.custom == true) "custom" else RenderVideo.rateText(choice.frameRate)
    var customText by remember(c) { mutableStateOf(RenderVideo.rateText(choice.frameRate)) }
    val customRate = RenderVideo.customRate(customText)
    Picker(localized("ui.frame_rate"), rateOptions, rateKey) { key ->
        customPicked = key == "custom"
        if (key == "custom") {
            // Kept at what it was, or a rate to start from; the field takes over from here.
            val rate = customRate ?: RenderVideo.customRate(RenderVideo.rateText(choice.frameRate)) ?: 24.0
            customText = RenderVideo.rateText(rate)
            choose(choice.copy(frameRate = rate))
        } else {
            key.toDoubleOrNull()?.let { choose(choice.copy(frameRate = it)) }
        }
    }
    if (rateEntry?.custom == true) {
        val problem = customRate == null
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
            if (problem) {
                Text(
                    localized("ui.enter_a_number_from_a_to_b", RenderVideo.rateText(RenderVideo.CUSTOM_MIN), RenderVideo.rateText(RenderVideo.CUSTOM_MAX)),
                    color = StarColors.red, fontSize = 10.sp, modifier = Modifier.weight(1f),
                )
            }
            BasicTextField(
                value = customText,
                onValueChange = { text ->
                    customText = text.filter { it.isDigit() || it == '.' }
                    // Applied as it is typed, so Render is never one keystroke behind what the field says.
                    RenderVideo.customRate(customText)?.let { choose(choice.copy(frameRate = it)) }
                },
                singleLine = true,
                textStyle = TextStyle(fontSize = 12.sp, color = StarColors.textPrimary),
                cursorBrush = SolidColor(StarColors.white),
                modifier = Modifier
                    .testTag("render.custom_frame_rate")
                    .width(80.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(StarColors.sidePanel)
                    .border(1.dp, if (problem) StarColors.red else StarColors.cellDefault, RoundedCornerShape(4.dp))
                    .padding(horizontal = 8.dp, vertical = 6.dp),
            )
            Text(localized("ui.frames_per_second"), color = StarColors.textSecondary, fontSize = 12.sp)
        }
    } else {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Text(localized("ui.frames_per_second"), color = StarColors.textSecondary, fontSize = 12.sp)
        }
    }
    Text(
        localized("ui.total_length").trim().removePrefix("-").trim() + " " + RenderVideo.formatLength(RenderVideo.lengthSeconds(frameCount, choice.frameRate)),
        color = StarColors.textSecondary, fontSize = 12.sp,
    )
    rateEntry?.description?.takeIf { it.isNotEmpty() }?.let { Description(it) }

    HorizontalDivider(color = StarColors.cellDefault)

    Picker(localized("ui.codec"), codecs.map { it.codec to it.codec }, choice.codec) { choose(choice.withCodec(c, it)) }
    codecCaps?.description?.takeIf { it.isNotEmpty() }?.let { Description(it) }

    Picker(localized("ui.encoder"), encoders.map { it.encoder to (if (it.description.isEmpty()) it.encoder else "${it.encoder} [${it.description}]") }, choice.encoder) {
        choose(choice.withEncoder(c, it))
    }
    Picker(localized("ui.pixel_format"), pixelFormats.map { it to it }, choice.pixelFormat) { choose(choice.copy(pixelFormat = it)) }
    // What the pixel format is made of: how many components, how many bits in all, and how deep each.
    pixelCaps?.let {
        Description(localized("ui.n_components_per_pixel", it.components))
        Description(localized("ui.n_bits_per_pixel", it.bitsPerPixel))
        if (it.bitDepths.isNotEmpty()) Description(localized("ui.bit_depths", it.bitDepths))
    }

    HorizontalDivider(color = StarColors.cellDefault)

    // Resolution: scaled to a height (the width follows the aspect ratio), or as the frames are.
    val resolutionOptions = RenderVideo.RESOLUTIONS.map { it.toString() to RenderVideo.resolutionText(it) }
    Picker(localized("ui.resolution"), resolutionOptions, choice.outputHeight.toString()) { choice = choice.copy(outputHeight = it.toInt()) }

    HorizontalDivider(color = StarColors.cellDefault)

    Picker(localized("ui.container"), muxers.map { it to it }, choice.muxer) { choose(choice.copy(muxer = it)) }
    muxerCaps?.let { Description("${it.description} - (.${it.fileExtension})") }

    HorizontalDivider(color = StarColors.cellDefault)

    // What the video will be called, which depends on the container: asked of the daemon, which names it.
    val fileName by produceState<String?>(null, choice.muxer) {
        value = app.sessions.sessionId?.let { sid -> runCatching { RenderVideo.fileName(app.export.defaultVideoPath(sid, choice.muxer)) }.getOrNull() }
    }
    Text(fileName ?: "…", color = StarColors.textPrimary, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)

    val canRender = choice.encoder.isNotEmpty() && (rateEntry?.custom != true || customRate != null)
    fun doRender() {
        if (!canRender) return
        app.startRender(choice.toSettings(), fileName ?: "")
    }
    // Auto-start when opened from the render prompt's "Yes" (once codecs and a default encoder load). Starting clears the flag, so changing the
    // codec afterwards does not start another.
    val autoStart by app.renderVideoAutoStart.collectAsState()
    LaunchedEffect(autoStart, choice.encoder) { if (autoStart && choice.encoder.isNotEmpty()) doRender() }

    Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
        OutlinedButton(onClick = app::closeRenderVideo) { Text(localized("ui.cancel")) }
        Button(
            enabled = canRender,
            onClick = { doRender() },
            colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
        ) { Text(localized("ui.render")) }
    }
}

/** What the render has got to: the file, the frame, a bar, and a Cancel that makes the daemon terminate ffmpeg. */
@Composable
private fun RenderingView(state: RenderState.Rendering, onCancel: () -> Unit) {
    Text(localized("ui.rendering_file", state.fileName), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
    Text(localized("ui.frame_n_of_m", state.current, state.total), color = StarColors.textSecondary, fontSize = 13.sp)
    LinearProgressIndicator(progress = { state.fraction }, modifier = Modifier.fillMaxWidth(), color = StarColors.green, trackColor = StarColors.cellDefault)
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.End) {
        OutlinedButton(onClick = onCancel, modifier = Modifier.testTag("render.cancel")) { Text(localized("ui.cancel")) }
    }
}

/** Where the video went, and the button that shows it. */
@Composable
private fun SucceededView(state: RenderState.Succeeded, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var problem by remember { mutableStateOf<String?>(null) }
    Text(renderedStatus(state.path, state.fileName), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp, modifier = Modifier.testTag("render.done"))
    state.path?.let { Text(it, color = StarColors.textSecondary, fontSize = 11.sp) }
    problem?.let { Text(it, color = StarColors.red, fontSize = 12.sp) }
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
        state.path?.let { path ->
            OutlinedButton(onClick = {
                scope.launch {
                    val shown = withContext(Dispatchers.IO) { FileReveal.reveal(File(path)) }
                    if (!shown) problem = localized("ui.could_not_open_the_file_manager_the_video_is_at", path)
                }
            }) { Text(revealLabel()) }
        }
        Button(onClick = onDismiss, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) { Text(localized("ui.dismiss")) }
    }
}

/** Why it failed: its own view, as on the Mac, with the message to read and copy. */
@Composable
private fun FailedView(state: RenderState.Failed, onDismiss: () -> Unit) {
    androidx.compose.foundation.text.selection.SelectionContainer {
        Text(localized("ui.rendering_error", state.message), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, modifier = Modifier.testTag("render.error"))
    }
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.End) {
        Button(onClick = onDismiss, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) { Text(localized("ui.dismiss")) }
    }
}

/**
 * What the dialog says once the video is written: "Successfully Rendered" and the file's name. [path] is where the daemon said it put it, which
 * names the file when the dialog did not (it asks for none); an engine that does not say gets [fallbackName].
 */
internal fun renderedStatus(path: String?, fallbackName: String = ""): String {
    val name = path?.takeIf { it.isNotEmpty() }?.let { RenderVideo.fileName(it) } ?: fallbackName
    return if (name.isEmpty()) localized("ui.done") else localized("ui.successfully_rendered", name)
}

/**
 * What the button says. A Mac has a Finder and the catalogue already says "Reveal In Finder" in every
 * language; Windows and Linux have no Finder, so they get the plain "Show In Folder".
 */
internal fun revealLabel(osName: String = System.getProperty("os.name").orEmpty()): String =
    if (FileReveal.platform(osName) == FileReveal.Platform.MAC) localized("ui.reveal_in_finder") else localized("ui.show_in_folder")

@Composable
private fun Description(text: String) {
    Text(text, color = StarColors.textSecondary, fontSize = 11.sp, modifier = Modifier.fillMaxWidth())
}

/** A picker of (value, shown) pairs: the value is what is chosen, the text is what the user reads. */
@Composable
private fun Picker(label: String, options: List<Pair<String, String>>, selected: String, onSelect: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, color = StarColors.textSecondary, fontSize = 12.sp)
        Box {
            Box(
                Modifier
                    .width(300.dp)
                    .clip(StarShapes.picker)
                    .background(StarColors.cellDefault)
                    .clickable(enabled = options.isNotEmpty()) { expanded = true }
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            ) {
                Text(
                    options.firstOrNull { it.first == selected }?.second ?: selected.ifEmpty { "—" },
                    color = StarColors.textPrimary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                options.forEach { (value, shown) ->
                    DropdownMenuItem(
                        text = { Text(shown, color = if (value == selected) StarColors.accent else StarColors.textPrimary, fontSize = 12.sp) },
                        onClick = { onSelect(value); expanded = false },
                    )
                }
            }
        }
    }
}
