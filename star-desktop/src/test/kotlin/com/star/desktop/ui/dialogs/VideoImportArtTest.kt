package com.star.desktop.ui.dialogs

import com.star.desktop.domain.FrameFormatChoice
import com.star.desktop.ui.components.StarArt
import kotlin.test.Test
import kotlin.test.assertEquals

class VideoImportArtTest {
    @Test fun everyFormatHasItsTile() {
        assertEquals(StarArt.ART_FORMAT_TIFF16, formatArt(FrameFormatChoice.TIFF16))
        assertEquals(StarArt.ART_FORMAT_TIFF8, formatArt(FrameFormatChoice.TIFF8))
        assertEquals(StarArt.ART_FORMAT_JPEG, formatArt(FrameFormatChoice.JPEG))
        assertEquals(FrameFormatChoice.entries.size, FrameFormatChoice.entries.map { formatArt(it) }.toSet().size)
    }
}
