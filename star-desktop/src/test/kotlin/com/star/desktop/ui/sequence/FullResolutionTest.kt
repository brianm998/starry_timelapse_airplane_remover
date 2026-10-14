package com.star.desktop.ui.sequence

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import com.star.desktop.data.ExportRepository
import com.star.desktop.data.FrameRepository
import com.star.desktop.data.HorizonRepository
import com.star.desktop.data.ImageCache
import com.star.desktop.data.OutlierRepository
import com.star.desktop.data.ProcessingRepository
import com.star.proto.SessionInfo
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertTrue

/** The collectors the view model starts in `init` read properties declared further down the class; they must exist by then. */
class FullResolutionTest {
    private val failures = CopyOnWriteArrayList<Throwable>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + CoroutineExceptionHandler { _, e -> failures += e })
    private val clientRequests = AtomicInteger()

    @AfterTest fun stop() { scope.cancel() }

    private fun vm(): SequenceViewModel {
        val info = SessionInfo.newBuilder().setSessionId("s").setFrameCount(5).setImageWidth(100).setImageHeight(100).build()
        return SequenceViewModel(
            scope, info, FrameRepository { clientRequests.incrementAndGet(); null }, ProcessingRepository(scope) { null },
            OutlierRepository { null }, ImageCache(), ExportRepository { null }, HorizonRepository { null },
        )
    }

    private suspend fun until(timeoutMs: Long = 3_000, condition: () -> Boolean): Boolean =
        withTimeoutOrNull(timeoutMs) { while (!condition()) delay(5); true } ?: false

    @Test fun openingASequenceStartsNoCollectorThatFails() = runBlocking {
        vm()
        delay(500)
        assertTrue(failures.isEmpty(), "a collector started in init failed: $failures")
    }

    /** Full resolution on and zoomed in asks the daemon for the full-size image; before, the collector had died at startup. */
    @Test fun zoomingInWithFullResolutionOnRequestsTheFullSizeImage() = runBlocking {
        val v = vm()
        delay(500)                                   // the first preview's lookups settle
        val before = clientRequests.get()
        v.setShowFullResolution(true)
        v.transform.zoomBy(3f, Offset.Zero, Size(50f, 50f))   // the image is 100 px wide: fit is 0.5, so this is allowed
        assertTrue(until { clientRequests.get() > before }, "no full-size image was requested")
        assertTrue(failures.isEmpty(), "$failures")
    }
}
