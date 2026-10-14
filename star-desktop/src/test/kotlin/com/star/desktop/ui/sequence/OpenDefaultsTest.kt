package com.star.desktop.ui.sequence

import com.star.desktop.data.ExportRepository
import com.star.desktop.data.FrameRepository
import com.star.desktop.data.HorizonRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.OutlierRepository
import com.star.desktop.data.ProcessingRepository
import com.star.proto.FrameViewMode
import com.star.desktop.domain.InteractionMode
import com.star.proto.SessionInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals

/** H10: what a sequence shows when it opens, as macOS opens it. */
class OpenDefaultsTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @AfterTest fun stop() { scope.cancel() }

    @Test fun aSequenceOpensOnItsOriginalFrames() {
        val info = SessionInfo.newBuilder().setSessionId("s").setFrameCount(5).setImageWidth(100).setImageHeight(100).build()
        val vm = SequenceViewModel(
            scope, info, FrameRepository { null }, ProcessingRepository(scope) { null }, OutlierRepository { null },
            ImageCache(), ExportRepository { null }, HorizonRepository { null },
        )
        assertEquals(FrameViewMode.VIEW_ORIGINAL, vm.viewMode.value)
        assertEquals(InteractionMode.SCRUB, vm.mode.value, "the view model's own start; the app moves a fresh source to edit")
    }

    @Test fun aFreshSourceStartsInEditAndAResumedOneInScrub() {
        assertEquals(InteractionMode.EDIT, InteractionMode.onOpening(freshSource = true))
        assertEquals(InteractionMode.SCRUB, InteractionMode.onOpening(freshSource = false))
    }
}
