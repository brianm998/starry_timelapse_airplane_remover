package com.star.desktop.ui.dialogs

import com.star.desktop.domain.RenderState
import com.star.desktop.ui.components.StarArt
import kotlin.test.Test
import kotlin.test.assertEquals

class RenderStateArtTest {
    @Test fun renderStateArt() {
        assertEquals(StarArt.ART_RENDERING, renderStateArt(RenderState.Rendering("a.mp4", 1, 10)))
        assertEquals(StarArt.ART_DONE, renderStateArt(RenderState.Succeeded("a.mp4", null)))
        assertEquals(StarArt.ART_OOPS, renderStateArt(RenderState.Failed("boom")))
    }
}
