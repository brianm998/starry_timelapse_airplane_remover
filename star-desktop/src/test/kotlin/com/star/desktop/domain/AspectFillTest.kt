package com.star.desktop.domain

import kotlin.test.Test
import kotlin.test.assertEquals

class AspectFillTest {
    @Test fun aPictureOfTheBoxsShapeShowsWhole() {
        assertEquals(AspectFill.Source(0, 0, 1920, 1080), AspectFill.source(1920, 1080, 1280, 720))
        assertEquals(AspectFill.Source(0, 0, 100, 100), AspectFill.source(100, 100, 7, 7))
    }

    @Test fun aWiderPictureLosesItsSidesEqually() {
        // 16:9 into a square: the full height, and the middle 1080 of the 1920 columns
        assertEquals(AspectFill.Source(420, 0, 1080, 1080), AspectFill.source(1920, 1080, 500, 500))
    }

    @Test fun aTallerPictureLosesItsTopAndBottomEqually() {
        // 16:9 into a window wider than that: the full width, and the middle of the rows
        val s = AspectFill.source(1920, 1080, 2000, 800)
        assertEquals(0, s.x)
        assertEquals(1920, s.width)
        assertEquals(768, s.height)
        assertEquals((1080 - 768) / 2, s.y)
    }

    @Test fun whatShowsHasTheShapeOfTheBox() {
        for ((dw, dh) in listOf(1280 to 800, 800 to 1280, 1000 to 1000, 3000 to 500, 500 to 3000)) {
            val s = AspectFill.source(1920, 1080, dw, dh)
            val shown = s.width.toDouble() / s.height
            val wanted = dw.toDouble() / dh
            assertEquals(wanted, shown, wanted * 0.01, "box ${dw}x$dh")
            assert(s.x >= 0 && s.y >= 0 && s.x + s.width <= 1920 && s.y + s.height <= 1080) { "inside the picture: $s" }
        }
    }

    @Test fun nothingToFitShowsWhatThereIs() {
        assertEquals(AspectFill.Source(0, 0, 100, 50), AspectFill.source(100, 50, 0, 0))
        assertEquals(AspectFill.Source(0, 0, 0, 0), AspectFill.source(0, 0, 100, 100))
    }
}
