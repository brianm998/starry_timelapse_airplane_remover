package com.star.desktop.ui.dialogs

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.i18n.localized

// Verbatim from gui/star/InfoDialogView.swift (InfoType.infoText).
private val ABOUT_TEXT = """
Star is the Starry Timelapse Airplane Remover.

This is software designed to post process timelapse image sequences from timelapses, with the intent of treating visual signals from airplanes and satellites as noise that should be removed.

It is free software, both free to use and free to see and use the source code, under the GPL v3 license.

At a high level, Star takes as input an image sequence from a timelapse video.
It does a bunch of processing on this, and then outputs a processed image sequence which has modifications made to it to hide streaks in the sky.
Currently Star does not operate on video files directly, only image sequences which are separated by folder, and only 16 bit tiff images.
""".trim()

private val HOW_TO_TEXT = """
To get started with Star, you need to first have an image sequence containing images from the night sky.

The fastest way to get started is to drop this folder into Star's starting screen, and then Star will load the sequence and let you view the sequence or start processing.

After first loading a new image sequence, Star will first generate previews for the original images. After preview generation, the original video can be played or scrubbed.

Before telling Star to start processing your image sequence, it can be helpful to describe an area at the bottom to ignore. Unless your video has no ground in it at all, it is helpful to go into edit mode, and turn on the 'Show Ignore Bar' switch on the right panel.
You can then drag up the orange arrows you see at the bottom of the screen to expose the area of the video to not process. This can speed Star up.
If your video is stationary, you can use a single frame to determine the cutoff for the ground.
If your video was taken on a moving tripod head, then it's best to scrub through the video to find the lowest place that the sky shows up, and use that frame for the cutoff.

Next, you can tell Star to start processing your image sequence.
Be aware that this can take some time. The Star interface remains active when processing, and you can look at each individual frame if you want to see what happens to it as it gets processed.

After processing, you will have a folder sitting alongside your original image sequence which contains the processed images.
These can then be rendered into the video format of your choice in the same workflow you usually use.

You will also have a json config file written out for your sequence, which can be reloaded at a later time to process the same sequence more.

The config can be loaded by dropping it onto Star's initial screen.
""".trim()

private val DETAILED_TEXT = """
Star processes each frame of a sequence in this manner:

Identify the horizon, if desired.
The first step is to maybe identify the horizon. This step is optional, as sometimes overnight timelapses don't have a horizon for some or all of the video. It also is faster to ignore the horizon, as less processing is done later. Knowing the horizon helps with better pixel replacement near and below the horizon, and less noise below the horizon due to earth alignment.

Identify a set of neighbor frames.
It is configurable how many neighbors are best to use, the default is 8. Using fewer can still work, but risks being unable to remove bad pixels in some really noisy situations.

Align the neighbor frames for sky and maybe earth too.
Star uses OpenCV's SIFT (Scale Invariant Feature Transform) to align neighboring frames with each frame being processed. If horizon detection is enabled, the horizon mask restricts keypoints to sky or ground. If alignment fails, Star falls back to the un-aligned neighbor frames (more noise).

Condense the aligned neighbor frames.
Star condenses the aligned neighbors into a single frame for the sky (and earth, if horizon detection is enabled), selecting each pixel via statistical analysis to remove pixels significantly brighter than others at the same location.

Subtract the aligned neighbor frame.
Star subtracts the aligned neighbor frame from the frame being processed, producing a grayscale image showing where the original was brighter. Airplanes and satellites show up as lines.

Detect Blobs.
Star detects 'Blobs' of brighter pixels by sorting pixels by brightness and growing regions from the brightest.

Blob Processing.
Numerous rounds of line detection and removal refine the blobs into a final set.

Outlier Group classification.
Blobs are promoted into Outlier Groups with classification features, then classified by a decision tree trained on validated sequences to decide which are noise.

Removal Mask Creation.
A removal mask (like a layer mask) marks the noisy pixels to overwrite from the aligned neighbor frame.

Final Bad Pixel Removal.
Star composites the frame with the aligned neighbor frame using the removal mask, overwriting only the noisy pixels.

After processing, you can watch a preview-resolution video of the sequence to make corrections.

Star is still a work in progress.
""".trim()

/** Tabs in the Info dialog (macOS `InfoType`). */
enum class InfoType(val shortName: String, val infoText: String) {
    ABOUT("About", ABOUT_TEXT),
    HOW_TO("How To", HOW_TO_TEXT),
    DETAILED("Detailed", DETAILED_TEXT),
}

/** Informational overlay (macOS `InfoDialogView`): picker of About/How To/Detailed + scrolling body. */
@Composable
fun InfoDialog(onClose: () -> Unit) {
    var selected by remember { mutableStateOf(InfoType.ABOUT) }
    Box(
        Modifier.fillMaxSize().background(Color(0.5f, 0.5f, 0.5f, 0.5f)).clickable(onClick = onClose),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .widthIn(max = 720.dp)
                .fillMaxHeight(0.8f)
                .clip(RoundedCornerShape(20.dp))
                .background(StarColors.prefsCard)
                .clickable(enabled = false) {}
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(localized("ui.information_about_star"), color = StarColors.white, fontWeight = FontWeight.SemiBold, fontSize = 24.sp)
            Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                com.star.desktop.ui.components.VerticalStarPicker(
                    options = InfoType.entries.toList(),
                    selected = selected,
                    label = { it.shortName },
                    onSelect = { selected = it },
                    modifier = Modifier.width(120.dp),
                )
                Text(
                    selected.infoText,
                    color = StarColors.white,
                    fontSize = 13.sp,
                    modifier = Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()),
                )
            }
            Button(onClick = onClose, colors = ButtonDefaults.buttonColors(containerColor = StarColors.accent)) {
                Text(localized("ui.close"))
            }
        }
    }
}
