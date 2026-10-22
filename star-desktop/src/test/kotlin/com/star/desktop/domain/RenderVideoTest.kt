package com.star.desktop.domain

import com.star.desktop.i18n.Strings
import com.star.proto.FrameRateCaps
import com.star.proto.VideoCapabilities
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RenderVideoTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    @Test fun aLengthIsHoursMinutesSecondsWithOnlyWhatIsNeeded() {
        assertEquals("0s", RenderVideo.formatLength(0.0))
        assertEquals("5s", RenderVideo.formatLength(5.4))
        assertEquals("1m 5s", RenderVideo.formatLength(65.0))
        assertEquals("1m 0s", RenderVideo.formatLength(60.0))
        assertEquals("1h 0m 0s", RenderVideo.formatLength(3600.0))
        assertEquals("2h 3m 4s", RenderVideo.formatLength(2 * 3600 + 3 * 60 + 4.0))
    }

    @Test fun aLengthThatIsNotANumberIsNothing() {
        assertEquals("0s", RenderVideo.formatLength(Double.NaN))
        assertEquals("0s", RenderVideo.formatLength(-3.0))
        assertEquals("0s", RenderVideo.formatLength(Double.POSITIVE_INFINITY))
    }

    @Test fun theLengthIsTheFramesOverTheRate() {
        assertEquals(10.0, RenderVideo.lengthSeconds(240, 24.0))
        assertEquals(0.0, RenderVideo.lengthSeconds(240, 0.0), "no rate, no length, rather than infinity")
        assertEquals(0.0, RenderVideo.lengthSeconds(240, Double.NaN))
    }

    @Test fun aRateIsReadAsTheMacReadsIt() {
        assertEquals("24", RenderVideo.rateText(24.0))
        assertEquals("29.97", RenderVideo.rateText(29.97))
        assertEquals("23.976", RenderVideo.rateText(23.976))
        assertEquals("12.5", RenderVideo.rateText(12.5))
        assertEquals("1000", RenderVideo.rateText(1000.0))
        assertEquals("0.01", RenderVideo.rateText(0.01))
    }

    @Test fun aCustomRateIsAnythingUpToAThousand() {
        assertEquals(12.5, RenderVideo.customRate("12.5"))
        assertEquals(1000.0, RenderVideo.customRate("1000"), "the top is in")
        assertEquals(0.01, RenderVideo.customRate("0.01"))
        assertNull(RenderVideo.customRate("1000.1"))
        assertNull(RenderVideo.customRate("0"), "the daemon refuses a rate of nothing")
        assertNull(RenderVideo.customRate(""))
        assertNull(RenderVideo.customRate("1.2.3"))
    }

    private val caps = VideoCapabilities.newBuilder()
        .addFrameRateCaps(FrameRateCaps.newBuilder().setValue(24.0).setDescription("cinema"))
        .addFrameRateCaps(FrameRateCaps.newBuilder().setValue(29.97).setDescription("ntsc"))
        .addFrameRateCaps(FrameRateCaps.newBuilder().setValue(24.0).setCustom(true).setDescription("any"))
        .build()

    @Test fun aStandardRateIsItsOwnEntry() {
        assertEquals("ntsc", RenderVideo.rateEntry(caps, 29.97)?.description)
        assertEquals("cinema", RenderVideo.rateEntry(caps, 24.0)?.description)
    }

    @Test fun anyOtherRateIsCustom() {
        val entry = RenderVideo.rateEntry(caps, 12.5)
        assertTrue(entry?.custom == true)
        assertEquals("any", entry?.description)
    }

    @Test fun customStaysPickedAtAStandardRate() {
        // Custom starts at the current rate, a standard one; looking it up by rate alone would hand back "cinema" and the field would never show.
        assertEquals("cinema", RenderVideo.shownRateEntry(caps, 24.0, customPicked = false)?.description)
        assertEquals("any", RenderVideo.shownRateEntry(caps, 24.0, customPicked = true)?.description)
        assertEquals("any", RenderVideo.shownRateEntry(caps, 12.5, customPicked = true)?.description)
    }

    @Test fun anEngineWithoutRatesHasNoEntry() {
        assertNull(RenderVideo.rateEntry(VideoCapabilities.getDefaultInstance(), 24.0))
    }

    @Test fun theFileNameIsWhatThePathEndsIn() {
        assertEquals("sky.mov", RenderVideo.fileName("/a/b/sky.mov"))
        assertEquals("sky.mkv", RenderVideo.fileName("sky.mkv"))
    }

    @Test fun onlyARenderUnderWayIsRendering() {
        assertTrue(RenderState.Rendering("a.mov", 1, 10).isRendering)
        assertFalse(RenderState.Choosing.isRendering)
        assertFalse(RenderState.Succeeded("a.mov", "/x/a.mov").isRendering)
        assertFalse(RenderState.Failed("no").isRendering)
    }

    @Test fun theBarFillsAsFramesAreEncoded() {
        assertEquals(0f, RenderState.Rendering("a", 0, 0).fraction, "before the first frame reports")
        assertEquals(0.25f, RenderState.Rendering("a", 25, 100).fraction)
        assertEquals(1f, RenderState.Rendering("a", 120, 100).fraction, "never past the end")
    }
}
