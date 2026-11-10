package com.star.desktop.util

import kotlin.test.Test
import kotlin.test.assertEquals

/** The machine may sleep with a sequence open and nothing running; it is held off from the start of a run, a render or an extraction to its end. */
class WorkSleepGuardTest {
    private class FakeBlocker : SleepBlocker {
        val calls = mutableListOf<String>()
        override fun acquire(): Boolean { calls += "acquire"; return true }
        override fun release() { calls += "release" }
    }

    @Test fun testNothingRunningHoldsNothing() {
        val blocker = FakeBlocker()
        val guard = WorkSleepGuard(blocker)
        guard.update(processing = false, rendering = false, extracting = false)
        guard.update(processing = false, rendering = false, extracting = false)
        assertEquals(emptyList(), blocker.calls)
    }

    @Test fun testEachKindOfWorkHoldsFromStartToEnd() {
        val blocker = FakeBlocker()
        val guard = WorkSleepGuard(blocker)
        guard.update(processing = true, rendering = false, extracting = false)
        guard.update(processing = false, rendering = false, extracting = false)
        guard.update(processing = false, rendering = true, extracting = false)
        guard.update(processing = false, rendering = false, extracting = false)
        guard.update(processing = false, rendering = false, extracting = true)
        guard.update(processing = false, rendering = false, extracting = false)
        assertEquals(listOf("acquire", "release", "acquire", "release", "acquire", "release"), blocker.calls)
    }

    @Test fun testOverlappingWorkReleasesOnlyWhenAllEnd() {
        val blocker = FakeBlocker()
        val guard = WorkSleepGuard(blocker)
        guard.update(processing = true, rendering = false, extracting = false)
        guard.update(processing = true, rendering = true, extracting = false)
        guard.update(processing = false, rendering = true, extracting = false)
        assertEquals(listOf("acquire"), blocker.calls)
        guard.update(processing = false, rendering = false, extracting = false)
        assertEquals(listOf("acquire", "release"), blocker.calls)
    }

    @Test fun testReleaseLetsGoWhileWorkIsRunning() {
        val blocker = FakeBlocker()
        val guard = WorkSleepGuard(blocker)
        guard.release()
        assertEquals(emptyList(), blocker.calls, "nothing held, nothing to release")
        guard.update(processing = true, rendering = false, extracting = false)
        guard.release()
        assertEquals(listOf("acquire", "release"), blocker.calls)
    }
}
