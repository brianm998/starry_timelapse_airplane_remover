package com.star.desktop.ui.dialogs

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import com.star.desktop.ui.components.StarArt
import com.star.desktop.ui.initial.WelcomeArt
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.i18n.localized

/** Where the source code lives (the repository is public); macOS `STAR_SOURCE_URL`. */
const val STAR_SOURCE_URL = "https://github.com/brianm998/starry_timelapse_airplane_remover"

/** The About tab's paragraphs, in order (macOS `InfoType.aboutKeys`); the source link goes after [ABOUT_LICENSE_KEY]. */
val ABOUT_KEYS = listOf(
    "ui.info_about_name",
    "ui.info_about_purpose",
    "ui.info_about_license",
    "ui.info_about_what_it_does",
    "ui.info_about_video_formats",
    "ui.info_about_image_formats",
)
const val ABOUT_LICENSE_KEY = "ui.info_about_license"

/** One step of the How To tab (macOS `HowToStep`): its robot, its heading and paragraph keys, and the keys of the button labels that fill `{0}`, `{1}`. */
data class HowToStep(val art: StarArt, val titleKey: String, val bodyKey: String, val placeholderKeys: List<String>) {
    val heading: String get() = localized(titleKey)
    val body: String get() = localized(bodyKey, *placeholderKeys.map { localized(it) }.toTypedArray())
}

/** The How To tab's five steps, in order (macOS `InfoType.howToSteps`). */
val HOW_TO_STEPS: List<HowToStep> = listOf(
    HowToStep(StarArt.ART_HOWTO_IMPORT, "ui.info_how_to_import_title", "ui.info_how_to_import_body",
        listOf("ui.load_video", "ui.load_image_sequence")),
    HowToStep(StarArt.ART_HOWTO_QUESTIONS, "ui.info_how_to_questions_title", "ui.info_how_to_questions_body",
        listOf("ui.processing_settings")),
    HowToStep(StarArt.ART_HOWTO_PROCESS, "ui.info_how_to_process_title", "ui.info_how_to_process_body",
        listOf("ui.start_processing")),
    HowToStep(StarArt.ART_REVIEW, "ui.info_how_to_review_title", "ui.info_how_to_review_body", emptyList()),
    HowToStep(StarArt.ART_RENDERING, "ui.info_how_to_render_title", "ui.info_how_to_render_body",
        listOf("ui.render_video", "ui.load_config")),
)

/** One section of the Detailed tab (macOS `DetailedSection`): the catalogue keys of its heading and body, and the stage picture that follows them. */
data class DetailedSection(val titleKey: String, val bodyKey: String, val art: StarArt) {
    val heading: String get() = localized(titleKey)
    val body: String get() = localized(bodyKey)

    /** The section's words as one string, heading first. */
    val text: String get() = heading + "\n" + body
}

/** The catalogue key of the Detailed tab's opening line, before the first section (macOS `InfoType.detailedOpeningKey`). */
const val DETAILED_OPENING_KEY = "ui.info_detailed_intro"

/** The Detailed tab's ten sections, in order (macOS `InfoType.detailedSections`). */
val DETAILED_SECTIONS: List<DetailedSection> = listOf(
    DetailedSection("ui.info_detailed_horizon_title", "ui.info_detailed_horizon_body", StarArt.ART_STAGE_HORIZON),
    DetailedSection("ui.info_detailed_neighbors_title", "ui.info_detailed_neighbors_body", StarArt.ART_STAGE_NEIGHBORS),
    DetailedSection("ui.info_detailed_aligned_title", "ui.info_detailed_aligned_body", StarArt.ART_STAGE_ALIGNED),
    DetailedSection("ui.info_detailed_condensed_title", "ui.info_detailed_condensed_body", StarArt.ART_STAGE_CONDENSED),
    DetailedSection("ui.info_detailed_subtraction_title", "ui.info_detailed_subtraction_body", StarArt.ART_STAGE_SUBTRACTION),
    DetailedSection("ui.info_detailed_blobs_title", "ui.info_detailed_blobs_body", StarArt.ART_STAGE_BLOBS),
    DetailedSection("ui.info_detailed_blob_processing_title", "ui.info_detailed_blob_processing_body", StarArt.ART_STAGE_BLOB_PROCESSING),
    DetailedSection("ui.info_detailed_classification_title", "ui.info_detailed_classification_body", StarArt.ART_STAGE_CLASSIFICATION),
    DetailedSection("ui.info_detailed_removal_mask_title", "ui.info_detailed_removal_mask_body", StarArt.ART_STAGE_REMOVAL_MASK),
    DetailedSection("ui.info_detailed_final_title", "ui.info_detailed_final_body", StarArt.ART_STAGE_FINAL),
)

/** The catalogue key of the paragraphs after the last section, joined by a blank line (macOS `InfoType.detailedClosingKey`). */
const val DETAILED_CLOSING_KEY = "ui.info_detailed_closing"

/** The Detailed tab's opening line. */
fun detailedOpening(): String = localized(DETAILED_OPENING_KEY)

/** The paragraphs after the last section. */
fun detailedClosing(): List<String> = localized(DETAILED_CLOSING_KEY).split("\n\n")

/** The Detailed tab as one string: the opening, the sections and the closing, in the language the app runs in. */
fun detailedText(): String = (listOf(detailedOpening()) + DETAILED_SECTIONS.map { it.text } + detailedClosing()).joinToString("\n\n")

/** Tabs in the Info dialog (macOS `InfoType`): each has its name in the catalogue and its text. */
enum class InfoType(val labelKey: String) {
    ABOUT("ui.about"),
    HOW_TO("ui.how_to"),
    DETAILED("ui.detailed");

    /** The tab's words as one string, in the language the app runs in (only the Detailed tab has one). */
    val infoText: String get() = if (this == DETAILED) detailedText() else ""
}

/**
 * Informational overlay (macOS `InfoDialogView`): picker of About / How To / Detailed + scrolling body. Which tab is up is the app's to remember
 * ([selected], macOS `ViewModel.currentInfoType`), so closing the dialog and opening it again finds the one that was being read.
 */
@Composable
fun InfoDialog(selected: InfoType, onSelect: (InfoType) -> Unit, onClose: () -> Unit) {
    Box(
        Modifier.fillMaxSize().background(Color(0.5f, 0.5f, 0.5f, 0.5f)).clickable(onClick = onClose),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .widthIn(max = WelcomeArt.bannerWidth)
                .fillMaxHeight(0.8f)
                .clip(RoundedCornerShape(20.dp))
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {},
        ) {
            // art_robot_and_dog cropped to the band that keeps the robot and dog whole, edge to edge so the dialog's corners clip it.
            val art = StarArt.ART_ROBOT_AND_DOG
            Box(Modifier.width(WelcomeArt.bannerWidth).height(WelcomeArt.bannerHeight).clipToBounds()) {
                Image(
                    painter = painterResource(art.resourcePath),
                    contentDescription = null,
                    contentScale = ContentScale.FillBounds,
                    modifier = Modifier.requiredSize(art.width.dp, art.height.dp)
                        .offset(y = -(art.height * WelcomeArt.BANNER_TOP).dp),
                )
            }
            Column(Modifier.weight(1f).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(localized("ui.information_about_star"), color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 24.sp)
            Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                com.star.desktop.ui.components.VerticalStarPicker(
                    options = InfoType.entries.toList(),
                    selected = selected,
                    label = { localized(it.labelKey) },
                    onSelect = onSelect,
                    modifier = Modifier.width(infoPickerWidth()),
                )
                Column(
                    Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    if (selected == InfoType.ABOUT) com.star.desktop.ui.components.ArtImage(StarArt.ART_WORDMARK)
                    if (selected == InfoType.ABOUT) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            com.star.desktop.ui.components.ArtImage(StarArt.ART_REAL_BEFORE)
                            val colour = StarColors.white.copy(alpha = 0.6f)
                            androidx.compose.foundation.Canvas(Modifier.size(16.dp)) {
                                val y = size.height / 2
                                val stroke = 1.5.dp.toPx()
                                drawLine(colour, androidx.compose.ui.geometry.Offset(1.dp.toPx(), y), androidx.compose.ui.geometry.Offset(size.width - 1.dp.toPx(), y), stroke)
                                drawLine(colour, androidx.compose.ui.geometry.Offset(size.width - 5.dp.toPx(), y - 4.dp.toPx()), androidx.compose.ui.geometry.Offset(size.width - 1.dp.toPx(), y), stroke)
                                drawLine(colour, androidx.compose.ui.geometry.Offset(size.width - 5.dp.toPx(), y + 4.dp.toPx()), androidx.compose.ui.geometry.Offset(size.width - 1.dp.toPx(), y), stroke)
                            }
                            com.star.desktop.ui.components.ArtImage(StarArt.ART_REAL_AFTER)
                        }
                    }
                    if (selected == InfoType.HOW_TO) {
                        WorkflowStrip()
                        for (step in HOW_TO_STEPS) HowToStepRow(step)
                    }
                    if (selected == InfoType.ABOUT) {
                        val uriHandler = androidx.compose.ui.platform.LocalUriHandler.current
                        for (key in ABOUT_KEYS) {
                            Text(localized(key), color = StarColors.white, fontSize = 13.sp)
                            if (key == ABOUT_LICENSE_KEY) {
                                Text(
                                    STAR_SOURCE_URL,
                                    color = StarColors.accent,
                                    fontSize = 13.sp,
                                    textDecoration = androidx.compose.ui.text.style.TextDecoration.Underline,
                                    modifier = Modifier.clickable { uriHandler.openUri(STAR_SOURCE_URL) },
                                )
                            }
                        }
                    } else if (selected == InfoType.DETAILED) {
                        Text(detailedOpening(), color = StarColors.white, fontSize = 13.sp)
                        for (section in DETAILED_SECTIONS) {
                            Text(section.heading, color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                            Text(section.body, color = StarColors.white, fontSize = 13.sp)
                            com.star.desktop.ui.components.ArtImage(section.art)
                        }
                        for (paragraph in detailedClosing()) Text(paragraph, color = StarColors.white, fontSize = 13.sp)
                    } else if (selected != InfoType.HOW_TO) {
                        Text(selected.infoText, color = StarColors.white, fontSize = 13.sp)
                    }
                }
            }
            Button(onClick = onClose, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) {
                Text(localized("ui.close"))
            }
            }
        }
    }
}

/** The picker's column: 120dp, or as wide as its widest label word needs (13sp, plus the 8dp padding of an option and the picker's own 2dp, each side). */
@Composable
internal fun infoPickerWidth(): androidx.compose.ui.unit.Dp =
    maxOf(120.dp, com.star.desktop.ui.components.widestWord(InfoType.entries.map { localized(it.labelKey) }, 13.sp) + 20.dp)

/** The six workflow steps the How To tab's strip shows, in order (macOS `workflowStripSteps`). */
internal val WORKFLOW_STRIP_STEPS: List<StarArt> = listOf(
    StarArt.ART_STEP_IMPORT, StarArt.ART_STEP_HORIZON, StarArt.ART_STEP_ALIGN,
    StarArt.ART_STEP_MERGE, StarArt.ART_STEP_REVIEW, StarArt.ART_STEP_RENDER,
)

/** A row of the six step tiles joined by small arrows drawn on a Canvas: 6 x 64 + 5 x 16 + 10 x 4 = 504dp. */
@Composable
internal fun WorkflowStrip() {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
        WORKFLOW_STRIP_STEPS.forEachIndexed { index, step ->
            if (index > 0) {
                val colour = StarColors.white.copy(alpha = 0.6f)
                androidx.compose.foundation.Canvas(Modifier.size(16.dp)) {
                    val y = size.height / 2
                    val stroke = 1.5.dp.toPx()
                    drawLine(colour, androidx.compose.ui.geometry.Offset(1.dp.toPx(), y), androidx.compose.ui.geometry.Offset(size.width - 1.dp.toPx(), y), stroke)
                    drawLine(colour, androidx.compose.ui.geometry.Offset(size.width - 5.dp.toPx(), y - 4.dp.toPx()), androidx.compose.ui.geometry.Offset(size.width - 1.dp.toPx(), y), stroke)
                    drawLine(colour, androidx.compose.ui.geometry.Offset(size.width - 5.dp.toPx(), y + 4.dp.toPx()), androidx.compose.ui.geometry.Offset(size.width - 1.dp.toPx(), y), stroke)
                }
            }
            com.star.desktop.ui.components.ArtImage(step)
        }
    }
}

/** A step: its robot beside a bold heading and the paragraph (macOS `HowToStepRow`). */
@Composable
internal fun HowToStepRow(step: HowToStep) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
        com.star.desktop.ui.components.ArtImage(step.art)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(step.heading, color = StarColors.white, fontWeight = FontWeight.Bold, fontSize = 15.sp)
            Text(step.body, color = StarColors.white, fontSize = 13.sp)
        }
    }
}
