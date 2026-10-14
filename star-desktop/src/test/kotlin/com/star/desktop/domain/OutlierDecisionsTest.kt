package com.star.desktop.domain

import com.star.proto.RemoveReason
import kotlin.test.Test
import kotlin.test.assertEquals

class OutlierDecisionsTest {
    private val decisions = mapOf(
        1 to RemoveReason.RR_UNDECIDED,
        2 to RemoveReason.RR_USER_REMOVE,
        3 to RemoveReason.RR_UNDECIDED,
        4 to RemoveReason.RR_CLASSIFIER_KEEP,
        5 to RemoveReason.RR_CLASSIFIER_REMOVE,
        6 to RemoveReason.RR_USER_KEEP,
    )

    /** Clear Undecided keeps the undecided groups, and only those (it used to set them to undecided: a no-op). */
    @Test fun clearingUndecidedKeepsTheUndecidedGroupsAndNothingElse() {
        val changes = OutlierDecisions.clearingUndecided(decisions.keys.toList()) { decisions.getValue(it) }
        assertEquals(listOf(1 to RemoveReason.RR_USER_KEEP, 3 to RemoveReason.RR_USER_KEEP), changes)
    }

    @Test fun nothingUndecidedMeansNothingToChange() {
        val changes = OutlierDecisions.clearingUndecided(listOf(2, 4, 5, 6)) { decisions.getValue(it) }
        assertEquals(emptyList(), changes)
    }

    /** A group the client has no decision for at all is undecided too. */
    @Test fun aGroupWithNoDecisionRecordedCountsAsUndecided() {
        val changes = OutlierDecisions.clearingUndecided(listOf(9)) { decisions[it] ?: RemoveReason.RR_UNDECIDED }
        assertEquals(listOf(9 to RemoveReason.RR_USER_KEEP), changes)
    }
}
