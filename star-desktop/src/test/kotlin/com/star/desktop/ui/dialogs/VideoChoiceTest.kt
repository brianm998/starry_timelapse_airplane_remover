package com.star.desktop.ui.dialogs

import com.star.proto.CodecCaps
import com.star.proto.Config
import com.star.proto.EncoderCaps
import com.star.proto.SessionInfo
import com.star.proto.VideoCapabilities
import com.star.proto.VideoEncodeSettings
import com.star.proto.VideoInfo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class VideoChoiceTest {
    private fun enc(name: String, pix: List<String>, mux: List<String>) =
        EncoderCaps.newBuilder().setEncoder(name).addAllPixelFormats(pix).addAllMuxers(mux).build()

    private val caps: VideoCapabilities = VideoCapabilities.newBuilder()
        .addAllFrameRates(listOf(24.0, 25.0, 30.0))
        .addCodecs(
            CodecCaps.newBuilder().setCodec("h264")
                .addEncoders(enc("libx264", listOf("yuv420p", "yuv444p"), listOf("mp4", "mov")))
                .addEncoders(enc("h264_videotoolbox", listOf("yuv420p"), listOf("mp4"))),
        )
        .addCodecs(
            CodecCaps.newBuilder().setCodec("prores")
                .addEncoders(enc("prores_ks", listOf("yuv422p10le"), listOf("mov", "matroska"))),
        )
        .build()

    private fun settings(codec: String = "", encoder: String = "", pix: String = "", mux: String = "", fps: Double = 0.0) =
        VideoEncodeSettings.newBuilder().setCodec(codec).setEncoder(encoder).setPixelFormat(pix).setMuxer(mux).setFrameRate(fps).build()

    /** With nothing stored, every level opens on its first entry (what the dialog always did). */
    @Test fun nothingStoredOpensOnTheFirstOfEverything() {
        assertEquals(VideoChoice("h264", "libx264", "yuv420p", "mp4", 24.0), resolveVideoChoice(caps, null))
    }

    /** The case that mattered: a 29.97 fps import rendered back at 24 fps, because the list's first rate was used. */
    @Test fun aStoredChoiceIsKeptWhereTheCapabilitiesAllowIt() {
        val c = resolveVideoChoice(caps, settings("prores", "prores_ks", "yuv422p10le", "matroska", 29.97))
        assertEquals(VideoChoice("prores", "prores_ks", "yuv422p10le", "matroska", 29.97), c)
    }

    /** A stored value the engine no longer offers falls to the first one that is valid at that level, and the levels below follow it. */
    @Test fun aStoredCodecTheEngineLacksFallsBackDownTheChain() {
        val c = resolveVideoChoice(caps, settings("av1", "libaom", "yuv420p", "webm", 30.0))
        assertEquals(VideoChoice("h264", "libx264", "yuv420p", "mp4", 30.0), c)
    }

    @Test fun aStoredEncoderOfAnotherCodecIsReplacedByThisCodecsFirst() {
        val c = resolveVideoChoice(caps, settings("h264", "prores_ks", "yuv422p10le", "matroska", 25.0))
        assertEquals("libx264", c.encoder)
        assertEquals("yuv420p", c.pixelFormat, "the pixel format has to be one the encoder offers")
        assertEquals("mp4", c.muxer, "the container has to be one the encoder offers")
    }

    @Test fun anUnusableStoredFrameRateIsReplacedByTheFirstStandardOne() {
        assertEquals(24.0, resolveVideoChoice(caps, settings("h264", fps = 0.0)).frameRate)
        assertEquals(24.0, resolveVideoChoice(caps, settings("h264", fps = -5.0)).frameRate)
    }

    @Test fun changingTheCodecRevalidatesTheRest() {
        val start = VideoChoice("h264", "libx264", "yuv444p", "mp4", 30.0)
        val prores = start.withCodec(caps, "prores")
        assertEquals(VideoChoice("prores", "prores_ks", "yuv422p10le", "mov", 30.0), prores)
    }

    @Test fun changingTheEncoderKeepsWhatItStillOffers() {
        val start = VideoChoice("h264", "libx264", "yuv420p", "mp4", 30.0)
        val hw = start.withEncoder(caps, "h264_videotoolbox")
        assertEquals(VideoChoice("h264", "h264_videotoolbox", "yuv420p", "mp4", 30.0), hw)
        val back = VideoChoice("h264", "libx264", "yuv444p", "mov", 30.0).withEncoder(caps, "h264_videotoolbox")
        assertEquals("yuv420p", back.pixelFormat)
        assertEquals("mp4", back.muxer)
    }

    // where the stored settings come from

    private fun session(videoFromSource: VideoEncodeSettings? = null, configVideo: VideoEncodeSettings? = null): SessionInfo {
        val b = SessionInfo.newBuilder()
        videoFromSource?.let { b.setSourceVideoInfo(VideoInfo.newBuilder().setSettings(it)) }
        configVideo?.let { b.setConfig(Config.newBuilder().setVideo(it)) }
        return b.build()
    }

    @Test fun theVideoAnImportCameFromComesFirst() {
        val s = storedVideoSettings(session(settings("prores", fps = 29.97), settings("h264", fps = 25.0)))
        assertEquals("prores", s?.codec)
        assertEquals(29.97, s?.frameRate)
    }

    @Test fun theConfigsRecordedSettingsComeNext() {
        assertEquals("h264", storedVideoSettings(session(configVideo = settings("h264", fps = 25.0)))?.codec)
    }

    @Test fun aSessionWithNeitherHasNothingStored() {
        assertNull(storedVideoSettings(session()))
        assertNull(storedVideoSettings(session(configVideo = settings(codec = ""))), "a config with no codec says nothing")
        assertNull(storedVideoSettings(null))
    }

    // ---- what a render starts from

    private fun remembered(codec: String = "", encoder: String = "", fps: Double = 0.0, pixelFormat: String = "", muxer: String = ""): VideoEncodeSettings =
        VideoEncodeSettings.newBuilder().setCodec(codec).setEncoder(encoder).setFrameRate(fps).setPixelFormat(pixelFormat).setMuxer(muxer).build()

    @Test fun anImportKeepsItsOwnRateWhateverWasChosenBefore() {
        val s = startingVideoSettings(session(videoFromSource = settings("prores", fps = 29.97)), remembered(codec = "h264", fps = 60.0))
        assertEquals("prores", s?.codec)
        assertEquals(29.97, s?.frameRate)
    }

    @Test fun otherwiseWhatTheUserLastChoseBeatsWhatTheConfigRecorded() {
        val s = startingVideoSettings(session(configVideo = settings("prores", fps = 24.0)), remembered(codec = "h264", fps = 30.0))
        assertEquals("h264", s?.codec)
        assertEquals(30.0, s?.frameRate)
    }

    /** The user chose a frame rate and never a codec: the codec is the config's, not nothing. */
    @Test fun aFieldTheUserNeverChoseStaysWhatTheConfigHas() {
        val s = startingVideoSettings(session(configVideo = settings("prores", fps = 24.0)), remembered(fps = 50.0))
        assertEquals("prores", s?.codec)
        assertEquals(50.0, s?.frameRate)
    }

    @Test fun withNothingRememberedItIsWhatWasStored() {
        assertEquals("prores", startingVideoSettings(session(configVideo = settings("prores")), null)?.codec)
        assertNull(startingVideoSettings(session(), null))
    }

    @Test fun whatWasChosenWithNothingStoredStillSeedsTheRender() {
        val s = startingVideoSettings(session(), remembered(codec = "h264", muxer = "mov"))
        assertEquals("h264", s?.codec)
        assertEquals("mov", s?.muxer)
    }

    /** The scale height goes to the daemon, and survives re-resolving the choice under a new codec. */
    @Test fun theOutputHeightIsSentAndSurvivesACodecChange() {
        val choice = resolveVideoChoice(caps, null).copy(outputHeight = 1080)
        assertEquals(1080, choice.toSettings().outputHeight)
        assertEquals(1080, choice.withCodec(caps, "prores").outputHeight)
        assertEquals(1080, choice.withEncoder(caps, "h264_videotoolbox").outputHeight)
        assertEquals(0, resolveVideoChoice(caps, null).toSettings().outputHeight, "0 means as the frames are")
    }
}
