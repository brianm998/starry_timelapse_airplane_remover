package com.star.desktop.domain

import com.star.proto.Warning
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class WarningRoutingTest {
    private fun warning(kind: String, severity: String = "warning", passing: Boolean = false) =
        Warning.newBuilder().setKind(kind).setSeverity(severity).setTitle(kind).setPassingCondition(passing).build()

    private val start = WarningState()

    @Test fun anOrdinaryWarningGoesToTheBannerAndNeverInterrupts() {
        val w = warning("outputWriteFailed")
        val s = WarningRouting.report(start, w, 10)
        assertSame(w, s.banner?.warning)
        assertNull(s.critical)
    }

    @Test fun aCriticalOneInterruptsTheFirstTime() {
        val w = warning("memoryPressure", "critical")
        val s = WarningRouting.report(start, w, 10)
        assertSame(w, s.critical)
        assertNull(s.banner, "it is the dialog's to say, not the banner's as well")
    }

    @Test fun acknowledgingItBringsItDownAndRemembersTheKind() {
        val s = WarningRouting.acknowledge(WarningRouting.report(start, warning("memoryPressure", "critical"), 10))
        assertNull(s.critical)
        assertNull(s.banner, "the user has just read it and said so")
        assertEquals(setOf("memoryPressure"), s.acknowledged)
    }

    /** The same condition happening again is said quietly: a dialog that came back every time would be one to click past. */
    @Test fun anAcknowledgedKindDoesNotInterruptAgainAndGoesToTheBanner() {
        var s = WarningRouting.acknowledge(WarningRouting.report(start, warning("memoryPressure", "critical"), 10))
        val again = warning("memoryPressure", "critical")
        s = WarningRouting.report(s, again, 20)
        assertNull(s.critical)
        assertSame(again, s.banner?.warning)
    }

    @Test fun anotherKindStillInterrupts() {
        val s = WarningRouting.acknowledge(WarningRouting.report(start, warning("memoryPressure", "critical"), 10))
        val other = warning("previousRunDied", "critical")
        assertSame(other, WarningRouting.report(s, other, 20).critical)
    }

    @Test fun theNewestBannerReplacesWhatWasThere() {
        var s = WarningRouting.report(start, warning("lowDiskSpace"), 10)
        val newer = warning("outputWriteFailed")
        s = WarningRouting.report(s, newer, 20)
        assertSame(newer, s.banner?.warning)
    }

    @Test fun onlyAWarningAboutAPassingConditionExpires() {
        assertEquals(60_000L, WarningRouting.lifetimeMs(warning("memoryPressure", passing = true)))
        assertNull(WarningRouting.lifetimeMs(warning("outputWriteFailed")), "it does not stop being true, so it stays until dismissed")
    }

    /** An engine that predates the flag still gets the three the Mac app lists. */
    @Test fun anEngineWithoutTheFlagIsAskedAboutTheKnownKinds() {
        for (kind in listOf("memoryPressure", "lowSystemMemory", "footprintOverBudget")) assertTrue(WarningRouting.passes(warning(kind)), kind)
        for (kind in listOf("outputWriteFailed", "lowDiskSpace", "previousRunDied", "memoryGatingDisabled")) assertFalse(WarningRouting.passes(warning(kind)), kind)
    }

    @Test fun theTimerComesTheBannerDownOnlyIfItIsStillThatBanner() {
        val first = WarningRouting.report(start, warning("memoryPressure", passing = true), 10)
        val firstBanner = first.banner!!
        assertNull(WarningRouting.expire(first, firstBanner).banner)

        val replaced = WarningRouting.report(first, warning("lowSystemMemory", passing = true), 30)
        assertEquals(replaced, WarningRouting.expire(replaced, firstBanner), "the first one's timer must not take down its replacement")
    }

    @Test fun theUserCanDismissTheBanner() {
        val s = WarningRouting.report(start, warning("lowDiskSpace"), 10)
        assertNull(WarningRouting.dismissBanner(s).banner)
    }

    @Test fun closingTheSequenceForgetsWhatWasAcknowledgedAndTakesTheBannerDown() {
        var s = WarningRouting.acknowledge(WarningRouting.report(start, warning("memoryPressure", "critical"), 10))
        s = WarningRouting.report(s, warning("lowDiskSpace"), 20)
        val reset = WarningRouting.reset(s)
        assertNull(reset.banner)
        assertTrue(reset.acknowledged.isEmpty())
    }

    /** The bytes stard sends, spelt out (its test pins the same): `38 01` is field 7, passing_condition, true. */
    @Test fun theFlagIsReadFromWhatStardSends() {
        val w = Warning.parseFrom(byteArrayOf(0x0A, 0x0E) + "memoryPressure".toByteArray() + byteArrayOf(0x38, 0x01))
        assertEquals("memoryPressure", w.kind)
        assertTrue(w.passingCondition)
    }
}
