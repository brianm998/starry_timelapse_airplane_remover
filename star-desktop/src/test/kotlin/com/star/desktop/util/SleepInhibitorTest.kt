package com.star.desktop.util

import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** H11: idle sleep is held off with what each system has for it, and let go again. */
class SleepInhibitorTest {
    @Test fun aMacHoldsItWithCaffeinateForAsLongAsTheAppRuns() {
        assertEquals(listOf("caffeinate", "-i", "-w", "4242"), SleepInhibitor.commandFor("Mac OS X", 4242))
    }

    @Test fun linuxHoldsItWithSystemdInhibitRunningSomethingThatEndsWithTheApp() {
        val command = SleepInhibitor.commandFor("Linux", 4242)!!
        assertEquals("systemd-inhibit", command.first())
        assertTrue("--what=idle" in command, "only idle sleep: $command")
        assertTrue("--pid=4242" in command, "it ends with the app: $command")
    }

    @Test fun windowsSetsTheExecutionStateFromAHelperThatWaitsForTheApp() {
        val command = SleepInhibitor.commandFor("Windows 11", 4242)!!
        assertEquals("powershell", command.first())
        val script = command.last()
        assertTrue("SetThreadExecutionState" in script)
        assertTrue("2147483649" in script, "ES_CONTINUOUS | ES_SYSTEM_REQUIRED, 0x80000001, in decimal")
        assertTrue("Wait-Process -Id 4242" in script, "it waits for the app: $script")
    }

    @Test fun aSystemWithNoWayToDoItHasNoCommand() {
        assertNull(SleepInhibitor.commandFor("Plan 9", 1))
    }

    /** A process that stays until stopped, standing in for the real command so that nothing on the machine is touched. */
    private fun fakeProcess(): Process = ProcessBuilder("sleep", "30").start()

    @Test fun acquiringStartsOneCommandAndReleasingStopsIt() {
        val started = ArrayList<Process>()
        val inhibitor = SleepInhibitor("Linux", 1) { started += fakeProcess(); started.last() }
        assertFalse(inhibitor.isHolding)
        assertTrue(inhibitor.acquire())
        assertTrue(inhibitor.isHolding)
        assertTrue(inhibitor.acquire(), "asking again while holding is fine")
        assertEquals(1, started.size, "and starts nothing more")

        inhibitor.release()
        assertFalse(inhibitor.isHolding)
        assertTrue(started.single().waitFor(5, TimeUnit.SECONDS), "the command was stopped")
    }

    @Test fun releasingWhenNothingIsHeldIsHarmless() {
        SleepInhibitor("Linux", 1) { null }.release()
    }

    @Test fun acquiringAgainAfterReleaseStartsAFreshOne() {
        val started = ArrayList<Process>()
        val inhibitor = SleepInhibitor("Mac OS X", 1) { started += fakeProcess(); started.last() }
        inhibitor.acquire(); inhibitor.release(); inhibitor.acquire()
        assertEquals(2, started.size)
        inhibitor.release()
    }

    @Test fun aCommandThatWillNotStartMeansNoHoldAndNoFailure() {
        val inhibitor = SleepInhibitor("Linux", 1) { null }
        assertFalse(inhibitor.acquire())
        assertFalse(inhibitor.isHolding)
    }

    @Test fun aSystemWithNoCommandMeansNoHoldAndNothingStarted() {
        var asked = false
        val inhibitor = SleepInhibitor("Plan 9", 1) { asked = true; null }
        assertFalse(inhibitor.acquire())
        assertFalse(asked)
    }

    @Test fun aHolderThatDiedIsReplacedOnTheNextAcquire() {
        val started = ArrayList<Process>()
        val inhibitor = SleepInhibitor("Linux", 1) { started += fakeProcess(); started.last() }
        inhibitor.acquire()
        started.single().destroyForcibly().waitFor(5, TimeUnit.SECONDS)
        assertFalse(inhibitor.isHolding, "a command that ended is not holding anything")
        assertTrue(inhibitor.acquire())
        assertEquals(2, started.size)
        inhibitor.release()
    }

    /** On a Mac the real command: it holds while the app lives and is gone after release. */
    @Test fun onAMacTheRealCaffeinateIsStartedAndStopped() {
        if (!System.getProperty("os.name").orEmpty().lowercase().contains("mac") || !java.io.File("/usr/bin/caffeinate").exists()) {
            println("[skip] onAMacTheRealCaffeinateIsStartedAndStopped — not a Mac with caffeinate")
            return
        }
        var process: Process? = null
        val inhibitor = SleepInhibitor { command -> process = ProcessBuilder(command).start(); process }
        assertTrue(inhibitor.acquire())
        val held = assertNotNull(process)
        Thread.sleep(300)
        assertTrue(held.isAlive, "caffeinate is holding")
        inhibitor.release()
        assertTrue(held.waitFor(5, TimeUnit.SECONDS), "caffeinate stopped when released")
    }
}
