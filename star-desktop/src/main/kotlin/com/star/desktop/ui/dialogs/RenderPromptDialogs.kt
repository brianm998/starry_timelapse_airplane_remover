package com.star.desktop.ui.dialogs

import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import com.star.proto.VideoCapabilities
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.components.HoverTip
import com.star.desktop.ui.components.defaultAction
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.theme.StarShapes
import com.star.desktop.i18n.localized
import com.star.desktop.ui.components.ArtImage
import com.star.desktop.ui.components.StarArt

/**
 * Pre-processing prompt (macOS `PreProcessingRenderPromptView`): auto-render after processing? Like the macOS
 * sheet it cannot be dismissed by clicking outside it (that used to cancel starting the run without a word), and
 * Return is "Yes", which goes on to the render options ([PreRenderOptionsDialog]) and starts nothing yet.
 */
@Composable
fun PreProcessingRenderPrompt(app: AppViewModel) {
    PromptCard(onScrimClick = null, onDefaultAction = app::chooseRenderOptions) {
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            ArtImage(StarArt.ART_RENDERING, fitting = 96)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(localized("ui.render_video_after_processing"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                Text(
                    localized("ui.once_frame_processing_finishes_would_you"),
                    color = StarColors.textSecondary, fontSize = 13.sp,
                )
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            HoverTip(localized("ui.start_processing_now_and_stop_showing_render")) {
                OutlinedButton(onClick = { app.confirmStartProcessing(autoRender = false, dontAskAgain = true) }) {
                    Text(localized("ui.don_t_ask_me_again"))
                }
            }
            Box(Modifier.weight(1f))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = { app.confirmStartProcessing(autoRender = false, dontAskAgain = false) }, modifier = Modifier.testTag("prompt.pre.no")) { Text(localized("ui.no")) }
                Button(
                    onClick = app::chooseRenderOptions,
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                    modifier = Modifier.testTag("prompt.pre.yes"),
                ) { Text(localized("ui.yes")) }
            }
        }
    }
}

/**
 * The second step of the pre-processing prompt (macOS `PreProcessingRenderOptionsView`), after Yes: how the video is to be rendered once the
 * frames are processed. The options are the Render Video dialog's. Cancel (and Esc) goes back to the question; Return is "Use These Settings".
 */
@Composable
fun PreRenderOptionsDialog(app: AppViewModel) {
    val caps by produceState<VideoCapabilities?>(null) { value = runCatching { app.export.capabilities() }.getOrNull() }
    val c = caps
    val state = remember(c) { c?.let { RenderOptionsState(it, storedVideoSettings(app.sessions.session.value)) } }
    fun confirm() { state?.takeIf { it.usable }?.let { app.confirmRenderOptions(it.choice.toSettings()) } }
    PromptCard(onScrimClick = null, onDefaultAction = ::confirm, onEscape = app::cancelRenderOptions) {
        Text(localized("ui.render_options_after_processing_title"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
        if (state == null) {
            Text(localized("ui.loading_codecs"), color = StarColors.textSecondary, fontSize = 13.sp)
        } else {
            Column(Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                RenderOptions(app, state, app.sessions.session.value?.frameCount ?: 0)
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
            OutlinedButton(onClick = app::cancelRenderOptions) { Text(localized("ui.cancel")) }
            if (state != null) {
                Button(
                    enabled = state.usable,
                    onClick = ::confirm,
                    colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                    modifier = Modifier.testTag("prompt.options.confirm"),
                ) { Text(localized("ui.use_these_settings")) }
            }
        }
    }
}

/**
 * The frame on screen as it was and as star left it, with an arrow between (macOS `beforeAndAfter`). Each picture is at
 * most 240 x 160 dp, aspect fit; the row is left out unless both pictures exist.
 */
@Composable
private fun loadBeforeAndAfter(app: AppViewModel): Pair<androidx.compose.ui.graphics.ImageBitmap, androidx.compose.ui.graphics.ImageBitmap>? {
    val index = app.currentFrameIndex
    val pictures by produceState<Pair<androidx.compose.ui.graphics.ImageBitmap, androidx.compose.ui.graphics.ImageBitmap>?>(null, index) {
        val before = app.framePicture(index, com.star.proto.FrameViewMode.VIEW_ORIGINAL)
        val after = app.framePicture(index, com.star.proto.FrameViewMode.VIEW_PROCESSED)
        value = if (before != null && after != null) before to after else null
    }
    return pictures
}

/** Lays out a given before / after pair (fill = false: a filling weight would stretch a picture past its 240 dp cap into any spare width): each picture at most 240 x 160 dp, shrinking (weight) in a narrow card. */
@Composable
internal fun BeforeAndAfterPictures(before: androidx.compose.ui.graphics.ImageBitmap, after: androidx.compose.ui.graphics.ImageBitmap) {
    val p = before to after
    @Composable
    fun picture(bitmap: androidx.compose.ui.graphics.ImageBitmap, modifier: Modifier, tag: String) =
        androidx.compose.foundation.Image(
            bitmap = bitmap,
            contentDescription = null,
            modifier = modifier.widthIn(max = 240.dp).heightIn(max = 160.dp).testTag(tag),
            contentScale = androidx.compose.ui.layout.ContentScale.Fit,
        )
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
        picture(p.first, Modifier.weight(1f, fill = false), "prompt.post.before")
        val arrowColor = StarColors.textSecondary
        androidx.compose.foundation.Canvas(Modifier.size(16.dp)) {
            val y = size.height / 2
            val stroke = 2.dp.toPx()
            drawLine(arrowColor, androidx.compose.ui.geometry.Offset(0f, y), androidx.compose.ui.geometry.Offset(size.width, y), stroke)
            drawLine(arrowColor, androidx.compose.ui.geometry.Offset(size.width, y), androidx.compose.ui.geometry.Offset(size.width * 0.6f, y - size.height * 0.3f), stroke)
            drawLine(arrowColor, androidx.compose.ui.geometry.Offset(size.width, y), androidx.compose.ui.geometry.Offset(size.width * 0.6f, y + size.height * 0.3f), stroke)
        }
        picture(p.second, Modifier.weight(1f, fill = false), "prompt.post.after")
    }
}

/** 24 + 116 (art) + 16 + 240 + 8 + 16 (arrow) + 8 + 240 + 24 = 692, rounded up: room for both pictures at 240 dp. */
internal val POST_PROMPT_MAX_WIDTH = 700.dp

/** Post-processing prompt (macOS `PostProcessingRenderPromptView`): render now / preview / cancel. Return is "Yes". */
@Composable
fun PostProcessingRenderPrompt(app: AppViewModel) {
    PostProcessingPromptCard(
        pictures = loadBeforeAndAfter(app),
        onDismiss = app::dismissPostRenderPrompt,
        onPreview = app::previewFinalFrames,
        onYes = app::confirmRenderAfterProcessing,
    )
}

/** The dialog itself, free of [AppViewModel] so a test can host it with a given picture pair. */
@Composable
internal fun PostProcessingPromptCard(
    pictures: Pair<androidx.compose.ui.graphics.ImageBitmap, androidx.compose.ui.graphics.ImageBitmap>?,
    onDismiss: () -> Unit,
    onPreview: () -> Unit,
    onYes: () -> Unit,
) {
    PromptCard(onScrimClick = onDismiss, onDefaultAction = onYes, maxWidth = POST_PROMPT_MAX_WIDTH) {
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            ArtImage(StarArt.ART_DONE)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(localized("ui.processing_complete"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                if (pictures != null) BeforeAndAfterPictures(pictures.first, pictures.second)
                Text(localized("ui.render_video_now"), color = StarColors.textSecondary, fontSize = 15.sp)
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = onDismiss, modifier = Modifier.testTag("prompt.post.cancel")) { Text(localized("ui.cancel")) }
            Box(Modifier.weight(1f))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                HoverTip(localized("ui.play_the_final_processed_frames_from_the")) {
                    OutlinedButton(onClick = onPreview, modifier = Modifier.testTag("prompt.post.preview")) { Text(localized("ui.preview_first")) }
                }
                HoverTip(localized("ui.render_now_using_the_current_settings")) {
                    Button(
                        onClick = onYes,
                        colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
                        modifier = Modifier.testTag("prompt.post.yes"),
                    ) { Text(localized("ui.yes")) }
                }
            }
        }
    }
}

/**
 * "Re-run horizon refinement now?" (macOS alert on `ImageSequenceView`): a reference horizon was saved and frames that
 * interpolate from it are stale. Hosted by the sequence screen, not by the painter, which closes when it saves. "Later"
 * is the cancel role (Esc, and the answer that starts nothing); Return is "Re-run Now".
 */
@Composable
fun HorizonRefinementPrompt(vm: com.star.desktop.ui.sequence.SequenceViewModel, prompt: com.star.desktop.ui.sequence.SequenceViewModel.RefinementPrompt) {
    PromptCard(onScrimClick = null, onDefaultAction = vm::runHorizonRefinement, onEscape = vm::deferHorizonRefinement) {
        Text(localized("ui.horizon_refinement_prompt_title"), color = StarColors.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
        Text(
            localized("ui.horizon_refinement_prompt_message", prompt.frameCount, prompt.renderCount),
            color = StarColors.textSecondary, fontSize = 13.sp,
        )
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
            OutlinedButton(onClick = vm::deferHorizonRefinement) { Text(localized("ui.horizon_refinement_later")) }
            Button(
                onClick = vm::runHorizonRefinement,
                colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent),
            ) { Text(localized("ui.horizon_refinement_now")) }
        }
    }
}

/** [onScrimClick] null means a click outside the card does nothing; [onDefaultAction] is what Return does, [onEscape] what Esc does. */
@Composable
internal fun PromptCard(
    onScrimClick: (() -> Unit)?,
    onDefaultAction: () -> Unit,
    onEscape: (() -> Unit)? = null,
    maxWidth: androidx.compose.ui.unit.Dp = 520.dp,
    content: @Composable () -> Unit,
) {
    Box(
        Modifier
            .fillMaxSize()
            .background(StarColors.scrim)
            .defaultAction(onDefaultAction, onEscape)
            .clickable(enabled = onScrimClick != null, onClick = { onScrimClick?.invoke() }),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .widthIn(min = 380.dp, max = maxWidth)
                .testTag("prompt.card")
                .clip(StarShapes.card)
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) { content() }
    }
}
