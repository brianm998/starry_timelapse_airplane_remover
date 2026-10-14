package com.star.desktop.ui.sequence.edit

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class FrameTransformTest {
    // A 4000 x 2000 image in an 1000 x 800 view: fit scale 0.25, drawn 1000 x 500, centred.
    private val canvas = Size(1000f, 800f)
    private fun transform() = FrameTransform(4000, 2000).also { it.canvasChanged(canvas) }

    private fun near(a: Float, b: Float, eps: Float = 0.01f) = abs(a - b) < eps

    @Test fun atFitTheWholeImageIsVisibleAndCentred() {
        val t = transform()
        assertEquals(0.25f, t.scale(canvas))
        assertEquals(Offset(0f, 150f), t.origin(canvas))
    }

    /** macOS cannot zoom out past fit, and neither can this (it used to go down to a tenth of it). */
    @Test fun itCannotZoomOutPastFit() {
        val t = transform()
        t.zoomBy(0.1f, Offset(500f, 400f), canvas)
        assertEquals(1f, t.userZoom)
        assertEquals(Offset.Zero, t.pan)
    }

    @Test fun theMostItZoomsToIsTheMaxScaleNotAConstant() {
        val t = transform()                       // max scale 1: 100%, i.e. 4x from fit
        t.zoomBy(100f, Offset(500f, 400f), canvas)
        assertTrue(near(4f, t.userZoom), "zoomed to ${t.userZoom}")
        t.setMaxScale(2f, canvas)
        t.zoomBy(100f, Offset(500f, 400f), canvas)
        assertTrue(near(8f, t.userZoom), "after raising the max, zoomed to ${t.userZoom}")
    }

    @Test fun loweringTheMaxPullsTheZoomBackInside() {
        val t = transform()
        t.setMaxScale(2f, canvas)
        t.zoomBy(100f, Offset(500f, 400f), canvas)     // 8x
        t.setMaxScale(1f, canvas)
        assertTrue(near(4f, t.userZoom))
    }

    @Test fun aSmallImageDoesNotZoomAtAll() {
        val small = FrameTransform(400, 200).also { it.canvasChanged(canvas) }   // fit scale 2.5, already past 100%
        small.zoomBy(5f, Offset(500f, 400f), canvas)
        assertEquals(1f, small.userZoom)
    }

    /** The point under the cursor stays under it. */
    @Test fun zoomingKeepsTheImagePointUnderTheFocusStill() {
        val t = transform()
        val focus = Offset(700f, 300f)
        val before = t.canvasToImage(focus, canvas)
        t.zoomBy(3f, focus, canvas)
        val after = t.canvasToImage(focus, canvas)
        assertTrue(near(before.x, after.x, 0.5f) && near(before.y, after.y, 0.5f), "$before -> $after")
    }

    /** At fit there is nowhere to pan to; zoomed in the image cannot be dragged off the view. */
    @Test fun panningIsLimitedToTheImage() {
        val t = transform()
        t.panBy(Offset(300f, 300f), canvas)
        assertEquals(Offset.Zero, t.pan)

        t.zoomBy(4f, Offset(500f, 400f), canvas)       // drawn 4000 x 2000 in 1000 x 800
        t.panBy(Offset(1e6f, 1e6f), canvas)
        assertEquals(Offset(1500f, 600f), t.pan)
        t.panBy(Offset(-1e6f, -1e6f), canvas)
        assertEquals(Offset(-1500f, -600f), t.pan)
    }

    @Test fun doubleClickGoesToActualSizeAndBack() {
        val t = transform()
        t.toggleFitActual(Offset(500f, 400f), canvas)
        assertTrue(near(1f, t.scale(canvas)), "scale after the first double-click: ${t.scale(canvas)}")
        t.toggleFitActual(Offset(500f, 400f), canvas)
        assertEquals(1f, t.userZoom)
    }

    @Test fun theSliderSetsAnAbsoluteScale() {
        val t = transform()
        t.setScale(0.5f, canvas)
        assertTrue(near(0.5f, t.scale(canvas)), "scale ${t.scale(canvas)}")
    }

    @Test fun aResizeKeepsTheZoomInsideTheNewLimits() {
        val t = transform()
        t.zoomBy(100f, Offset(500f, 400f), canvas)
        t.canvasChanged(Size(500f, 400f))            // fit scale now 0.125: 100% is 8x
        assertTrue(near(8f, t.userZoom) || t.userZoom <= 8.01f)
    }

    @Test fun aNotchOfTheWheelZoomsByTenPercent() {
        assertTrue(near(1.1f, FrameTransform.zoomFactor(-1f), 0.001f))
        assertTrue(near(1f / 1.1f, FrameTransform.zoomFactor(1f), 0.001f))
        assertEquals(1f, FrameTransform.zoomFactor(0f))
    }
}

class FormatScaleTest {
    @Test fun aWholeScaleHasNoDecimals() {
        assertEquals("1", com.star.desktop.ui.sequence.formatScale(1f))
        assertEquals("10", com.star.desktop.ui.sequence.formatScale(10f))
    }

    @Test fun aFractionalScaleIsTrimmed() {
        assertEquals("2.5", com.star.desktop.ui.sequence.formatScale(2.5f))
        assertEquals("0.25", com.star.desktop.ui.sequence.formatScale(0.25f))
        assertEquals("1.33", com.star.desktop.ui.sequence.formatScale(1.3333f))
    }
}
