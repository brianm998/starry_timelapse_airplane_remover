package com.star.desktop.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.star.desktop.domain.AlignmentData
import com.star.desktop.i18n.Strings
import com.star.desktop.ui.theme.StarTheme
import com.star.proto.AlignmentInfo
import com.star.proto.AlignmentState
import com.star.proto.HomographyResults
import com.star.proto.NeighborHomography
import org.jetbrains.skia.EncodedImageFormat
import java.io.File
import kotlin.math.sin
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Draws the alignment charts off screen (no window, so no screen access is needed), to see that they compose and put something on the page:
 * lines in several colours, the red marks of the distrusted warps, a red current-frame line, axis text, and a tooltip under a hovering
 * pointer. With `-Dstar.render.dump=<dir>` the pictures are written there for looking at.
 */
@OptIn(ExperimentalComposeUiApi::class)
class AlignmentChartRenderTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private val frames = 300

    /** A sequence with a drifting alignment: each neighbor's deviation follows a slow wave, a few of them distrusted. */
    private fun data(): AlignmentData = AlignmentData(
        (0 until frames).map { f ->
            val neighbors = listOf(-3, -2, -1, 1, 2, 3).filter { f + it in 0 until frames }.map { off ->
                NeighborHomography.newBuilder().setFrameIndex(f + off)
                    .setDeviation(kotlin.math.abs(off) * (8.0 + 6.0 * sin(f / 20.0)))
                    .setState(AlignmentState.ALIGN_HOMOGRAPHY_SUCCESS)
                    .setSuspect(f % 37 == 0 && off == 2).build()
            }
            AlignmentInfo.newBuilder().setFrameIndex(f).setHasStarResults(true)
                .setNumSkyKeypoints(1500 + (300 * sin(f / 15.0)).toInt())
                .setStar(HomographyResults.newBuilder().setFrameIndex(f).addAllNeighbors(neighbors)).build()
        },
    )

    /** The pictures a chart makes, as rendered with [act] done to the scene first, with the frames clicked on collected into [picked]. */
    private fun render(name: String, picked: MutableList<Int> = mutableListOf(), act: (ImageComposeScene) -> Unit = {}): org.jetbrains.skia.Bitmap {
        val alignment = data()
        val scene = ImageComposeScene(width = 900, height = 760, density = Density(1f)) {
            StarTheme {
                Column(Modifier.fillMaxSize().padding(8.dp)) {
                    DeviationChart(alignment.starPoints, frames, current = 120, onPick = { picked += it }, chartHeight = 300.dp)
                    KeypointChart(alignment.skyKeypoints, frames, current = 120, onPick = {}, chartHeight = 240.dp)
                }
            }
        }
        try {
            scene.render()
            act(scene)
            val image = scene.render(100_000_000)
            val bytes = image.encodeToData(EncodedImageFormat.PNG)!!.bytes
            System.getProperty("star.render.dump")?.takeIf { it.isNotBlank() }?.let { File(it, "$name.png").apply { parentFile.mkdirs() }.writeBytes(bytes) }
            return org.jetbrains.skia.Bitmap.makeFromImage(image)
        } finally {
            scene.close()
        }
    }

    private fun hover(scene: ImageComposeScene, at: Offset) {
        scene.sendPointerEvent(PointerEventType.Enter, at)
        scene.render(16_000_000)
        scene.sendPointerEvent(PointerEventType.Move, at + Offset(1f, 1f))
        scene.render(32_000_000)
    }

    private fun countPixels(bitmap: org.jetbrains.skia.Bitmap, test: (Int, Int, Int) -> Boolean): Int {
        var n = 0
        for (y in 0 until bitmap.height step 2) for (x in 0 until bitmap.width step 2) {
            val c = bitmap.getColor(x, y)
            if (test((c shr 16) and 0xff, (c shr 8) and 0xff, c and 0xff)) n++
        }
        return n
    }

    private fun differs(a: org.jetbrains.skia.Bitmap, b: org.jetbrains.skia.Bitmap): Boolean {
        for (y in 0 until a.height step 2) for (x in 0 until a.width step 2) if (a.getColor(x, y) != b.getColor(x, y)) return true
        return false
    }

    @Test fun theChartsDrawLinesMarksAndTheCurrentFrame() {
        val picture = render("alignment_charts")
        val red = countPixels(picture) { r, g, b -> r > 200 && g < 90 && b < 90 }
        val colored = countPixels(picture) { r, g, b -> maxOf(r, g, b) - minOf(r, g, b) > 80 }
        assertTrue(red > 20, "no red: the current-frame line and the distrusted warps are red ($red)")
        assertTrue(colored > 400, "the offsets' lines were not drawn in colour ($colored)")
    }

    @Test fun hoveringAReadingShowsATooltip() {
        val plain = render("alignment_charts_plain")
        val hovered = render("alignment_charts_hover") { hover(it, Offset(400f, 150f)) }
        assertTrue(differs(plain, hovered), "a pointer over the chart changed nothing")
    }

    @Test fun theWheelZoomsTheChart() {
        val plain = render("alignment_charts_plain")
        val zoomed = render("alignment_charts_zoomed") { scene ->
            hover(scene, Offset(400f, 150f))
            scene.sendPointerEvent(PointerEventType.Scroll, Offset(400f, 150f), scrollDelta = Offset(0f, -4f))
            scene.render(48_000_000)
        }
        assertTrue(differs(plain, zoomed), "the wheel did nothing")
    }

    @Test fun draggingPansAZoomedChart() {
        val zoomed = render("alignment_charts_zoomed_only") { scene ->
            hover(scene, Offset(400f, 150f))
            scene.sendPointerEvent(PointerEventType.Scroll, Offset(400f, 150f), scrollDelta = Offset(0f, -6f))
            scene.render(48_000_000)
        }
        val panned = render("alignment_charts_panned") { scene ->
            hover(scene, Offset(400f, 150f))
            scene.sendPointerEvent(PointerEventType.Scroll, Offset(400f, 150f), scrollDelta = Offset(0f, -6f))
            scene.render(48_000_000)
            scene.sendPointerEvent(PointerEventType.Press, Offset(400f, 150f), buttons = androidx.compose.ui.input.pointer.PointerButtons(isPrimaryPressed = true))
            scene.render(64_000_000)
            for (step in 1..10) {
                scene.sendPointerEvent(PointerEventType.Move, Offset(400f - step * 30f, 150f), buttons = androidx.compose.ui.input.pointer.PointerButtons(isPrimaryPressed = true))
                scene.render(64_000_000L + step * 16_000_000L)
            }
            scene.sendPointerEvent(PointerEventType.Release, Offset(100f, 150f))
            scene.render(300_000_000)
        }
        assertTrue(differs(zoomed, panned), "dragging did not move the chart")
    }

    @Test fun clickingAFrameGoesToIt() {
        val picked = mutableListOf<Int>()
        render("alignment_charts_click", picked) { scene ->
            hover(scene, Offset(400f, 150f))
            scene.sendPointerEvent(PointerEventType.Press, Offset(400f, 150f), buttons = androidx.compose.ui.input.pointer.PointerButtons(isPrimaryPressed = true))
            scene.render(64_000_000)
            scene.sendPointerEvent(PointerEventType.Release, Offset(400f, 150f))
            scene.render(80_000_000)
        }
        assertTrue(picked.size == 1, "one click is one pick: $picked")
        // The plot runs from x=62 to x=890 over frames 0..299: the click at 400 is a bit past frame 120.
        assertTrue(picked.single() in 115..135, "picked ${picked.single()}")
    }
}
