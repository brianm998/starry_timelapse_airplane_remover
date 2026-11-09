package com.star.desktop.ui.sequence

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.runComposeUiTest
import com.star.desktop.i18n.Strings
import com.star.desktop.ui.theme.StarTheme
import com.star.proto.FrameEtaResponse
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * The panel over a frame that is not extracted yet asks the engine for its ETA about once a second. That poll must not keep the Compose test
 * clock busy: a `LaunchedEffect { while (true) { ...; delay(1000) } }` always has a delay pending on it, so `waitForIdle` (which every semantics
 * query calls) spins, with `autoAdvance` on, for as long as the panel is shown. The Gherkin painter-waits-for-extraction scenario hung on that.
 */
@OptIn(ExperimentalTestApi::class)
class FrameWaitPanelTest {
    @Test fun testWaitForIdleReturnsWhileTheEtaIsPolled() {
        val asked = AtomicInteger()
        val finished = java.util.concurrent.atomic.AtomicBoolean(false)
        val failure = java.util.concurrent.atomic.AtomicReference<Throwable?>(null)
        // runComposeUiTest has no real-time limit of its own, so it runs on a helper thread that is abandoned if it spins
        val runner = thread(isDaemon = true, name = "FrameWaitPanelTest") {
            try {
                runComposeUiTest {
                    Strings.setOverride("en")
                    setContent {
                        StarTheme {
                            FrameWaitPanelContent(1, true, { asked.incrementAndGet(); FrameEtaResponse.getDefaultInstance() })
                        }
                    }
                    waitForIdle()
                    onNodeWithTag("extraction.waitpanel").assertExists()
                }
                finished.set(true)
            } catch (t: Throwable) {
                failure.set(t)
            }
        }
        runner.join(20_000)
        failure.get()?.let { throw it }
        assertTrue(finished.get(), "waitForIdle did not return within 20 s while the wait panel polled for an ETA")
        assertTrue(asked.get() >= 1, "the panel never asked for the ETA")
    }
}
