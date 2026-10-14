package com.star.desktop.domain

import com.star.proto.RemoveReason

/**
 * Helpers over the proto [RemoveReason] enum (mirrors macOS `RemoveReason`).
 *
 * Note: the daemon returns outlier group ids as proto `uint32`. In generated Java/Kotlin those
 * arrive as a signed `Int` whose bit pattern is the unsigned value; treat ids opaquely and compare
 * by equality — never narrow or sign-extend them (a v1 bug corrupted ids > 2^31).
 */
object OutlierDecisions {

    /** True if this group will be painted out (removed), false if kept, null if undecided. */
    fun willRemove(reason: RemoveReason): Boolean? = when (reason) {
        RemoveReason.RR_USER_REMOVE, RemoveReason.RR_CLASSIFIER_REMOVE -> true
        RemoveReason.RR_USER_KEEP, RemoveReason.RR_CLASSIFIER_KEEP -> false
        else -> null // RR_UNDECIDED / unrecognized
    }

    fun isDecided(reason: RemoveReason): Boolean = willRemove(reason) != null

    fun isUserDecision(reason: RemoveReason): Boolean =
        reason == RemoveReason.RR_USER_REMOVE || reason == RemoveReason.RR_USER_KEEP

    /**
     * Toggle a click: the macOS app sets `userSelected(!willPaint)` — clicking flips the current
     * decision. An undecided/kept group becomes user-remove; a removed group becomes user-keep.
     */
    fun toggled(reason: RemoveReason): RemoveReason =
        if (willRemove(reason) == true) RemoveReason.RR_USER_KEEP else RemoveReason.RR_USER_REMOVE
}
