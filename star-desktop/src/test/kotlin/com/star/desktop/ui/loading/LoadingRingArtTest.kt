package com.star.desktop.ui.loading

import androidx.compose.ui.unit.dp
import kotlin.test.Test
import kotlin.test.assertEquals

class LoadingRingArtTest {
    @Test
    fun loadingRingArtSize() {
        // The determinate ring is 160 dp with a 10 dp stroke: inner 140, 60% is 84.
        assertEquals(84f, loadingRingArtSize(160.dp, 10.dp).value, 0.001f)
        // A big ring is capped at 120.
        assertEquals(120f, loadingRingArtSize(580.dp, 80.dp).value, 0.001f)
        // A small ring scales: inner 100 -> 60.
        assertEquals(60f, loadingRingArtSize(260.dp, 80.dp).value, 0.001f)
        // No inner room, no robot.
        assertEquals(0f, loadingRingArtSize(160.dp, 80.dp).value, 0.001f)
    }
}
