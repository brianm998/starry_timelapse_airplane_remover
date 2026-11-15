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

private val HOW_TO_TEXT = """
To get started with Star, you need to first have an image sequence containing images from the night sky.

The fastest way to get started is to drop this folder into Star's starting screen, and then Star will load the sequence and let you view the sequence or start processing.

After first loading a new image sequence, Star will first generate previews for the original images.  After preview generation, the original video can be played or scrubbed.

Before telling Start to start processing your image sequence, it can be helpful to desribe an area at the bottom to ignore.  Unless you video has no ground in it at all, it is helpful to go into edit mode, and turn on the 'Show Ignore Bar' switch on the right panel.
You can then drag up the orange arrows you see at the bottom of the screen to expose the are of the video to not process.   This can speed Star up.
If you video is stationary, you can use a single frame to determine the cutoff for the ground.
If your video was taking on moving tripod head, then it's best to scrub through the video to find the lowest place that the sky shows up, and use that frame for the cutoff.

Next, you can tell Star to start processing your image sequence.
Be aware that this can take some time.  The Star interface remains active when processing, and you can look at each individual frame if you want to see what happens to it as it gets processed.

After processing, you will have a folder sitting alongside your original image sequence which contains the processed images.
These can then be renedred into the video format of your choice in the same workflow you usually use.

You will also have a json config file written out for your sequence, which can be reloaded at a later time to process the same sequence more.

The config can be loaded by dropping it onto Star's initial screen.
""".trimIndent()

private val DETAILED_TEXT = """
Star processes each frame of a sequence in this manner:

Identify the horizon, if desired.

The first step is to maybe identify the horizon.  This step is optional, as sometimes overnight timelapses don't have a horizon for some or all of the video.  It also is faster to ignore the horizon, as less processing is done later.
However, knowing the horizon can help in a number of ways:
 - better pixel replacement close to the horizon
 - better pixel replacement below the horizon
 - less noise below the horizon due to earth alignment 

Identify a set of neighbor frames.

It is configurable how many neighbors are best to use, the default is 8.  Using less can still work, but risks being unable to remove bad pixels in some really noisy situations.

Align the neighbor frames for sky and maybe earth too.

Star uses opencv2 for its SIFT (Scale Invariant Feature Transform) logic to align neibhgoring frames with each frame being processed.
If horizon detection is enabled, the calculated horizon mask for the frame being procssed is used to only identify keypoints in either the sky or the ground.  Without horizon detection, the whole image is scanned for keypoints, which almost always ends up aligning the sky.
If the alignment fails to properly align the frames, Star will fall back to simply using the un-aligned neighbor frames.  This does work, but results in more noise during processing, and the overwritten data is going to be slightly off.

Condense the aligned neighbor frames.

After aligning some set of neighbor frames for the frame being procssed, star will then condense this set of frames into a single frame for the sky, and also the earth, if horizon detection is enabled.
Each pixel is selected from neighboring frames using statistical analysis to remove pixels that are significally brighter than others in the same x,y location in other frames.
You can see the star and earth aligned images for each frame and how well is is aligned in edit mode.

Subtract the aligned neighbor frame.

Next, Star will subtract the aligned neighbor frame from the frame being processed.
This results in a new grayscale image which indicates where, and by how much, the original frame was brighter than the neighbor frame.
If horizon detection is enabled, the calculated horizon mask for the frame being processd will be used.  This way, the earth alignment image is used as well as the sky alignment image.
You can see the subtraction image for each frame in edit mode.
While a lot of other things will show up in the subtraction image, you will see any airplanes or satellites as lines, ideally without any stars or static lights on the ground.

Detect Blobs
Next Star detects what are called Blobs of brighter pixels, using an algorithm that sorts all of the pixels in an image by brightness, and then processing them in order of brighest first, stopping on dimmer pixels.
Each bright pixel is then looked at, and any neighbors that aren't too dark are added to the 'Blob'
You can see the initial blobs for each frame in edit mode.

Blob Processing
After initial Blob detection, a lot of processing is done to make the signal cleaner.
Numerous rounds of line detection and removal based upon different criteria end up giving a final set of blobs.
You can see how the many different blob processing steps work for each frame in edit mode.

Outlier Group classification.
After Blob processing is complete, the Blobs are promoted into Outlier Groups.
Both Blobs and Outlier Groups contain a list of pixels in the frame being processed that may contain 'noise' that should be removed.
Outlier Groups add a layer of classification features on top of Blobs, which are used to tell which ones are really noise that should be removed.
These classification features can be as simple as number of pixels, or more complex, involving neighboring frames and other neighboring outlier groups in the same frame.
To classify the outlier groups, Star uses a decision tree based upon validated sequences.
To validate a sequence means processing it through Star and then manually playing the video and correcting bad classifications by hand on each frame.  This can take while.

Removal Mask Creation.
After classifying all of the Outlier Groups for a frame, we now know which pixels are considered noise and which ones are ok to keep.
With this data, Star then creates a removal mask, similar to a layer mask in Photoshop or the GIMP.  This mask is used to remove any noisy pixels with data from the aligned neighbor frame.

Final Bad Pixel Removal
At this final step, Star simply composts the frame being processed with the aligned neighor frame, using the removal mask as a layer mask, to only overwrite a small number of pixels in the frame we are processing.

After Star has finished processing your image sequence, you can then watch a video of the sequence at preview resolution.  This can be helpful to allow you to make any corrections.

Star is still a work in progress.
""".trimIndent()

/** Tabs in the Info dialog (macOS `InfoType`): each has its name in the catalogue and its text. */
enum class InfoType(val labelKey: String, val infoText: String) {
    ABOUT("ui.about", ""),
    HOW_TO("ui.how_to", HOW_TO_TEXT),
    DETAILED("ui.detailed", DETAILED_TEXT),
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
                    if (selected == InfoType.HOW_TO) WorkflowStrip()
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
                    } else {
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
