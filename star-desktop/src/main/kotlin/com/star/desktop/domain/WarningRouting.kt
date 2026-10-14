package com.star.desktop.domain

import com.star.proto.Warning

/** A warning in the banner, and when it arrived: that is what tells a timer that went off for it from one that went off for its replacement. */
data class BannerWarning(val warning: Warning, val receivedAtMs: Long)

/** The warnings the app is showing: the one in the banner, the critical one over the window, and the kinds the user has already been interrupted about. */
data class WarningState(
    val banner: BannerWarning? = null,
    val critical: Warning? = null,
    val acknowledged: Set<String> = emptySet(),
)

/**
 * Where a warning from the engine goes (macOS `ViewModel.report(warning:)`).
 *
 * Only a critical one interrupts: the system about to start killing processes, a run that was killed. A warning, such as star pausing work
 * because the machine is busy, is something the user may want to know and need not act on, and a modal for it would teach them to dismiss the
 * modal that matters, so it goes to the banner. After a critical one has been acknowledged, its kind does not interrupt again: it is said quietly,
 * in the banner, when it happens again. A banner about a state that passes on its own comes down by itself after a minute; one about something
 * that happened stays until it is dismissed, since it does not stop being true. Closing the sequence forgets what was acknowledged.
 */
object WarningRouting {
    /** How long a banner about a passing condition stays up. */
    const val BANNER_LIFETIME_MS = 60_000L

    /** What passes on its own, for an engine that does not say (StarCore's `describesAPassingCondition`). */
    private val PASSING_KINDS = setOf("memoryPressure", "lowSystemMemory", "footprintOverBudget")

    fun passes(warning: Warning): Boolean = warning.passingCondition || warning.kind in PASSING_KINDS

    /** How long a banner showing [warning] stays, or null for until it is dismissed. */
    fun lifetimeMs(warning: Warning): Long? = if (passes(warning)) BANNER_LIFETIME_MS else null

    /** [warning] arrives: to the banner (the newest replaces what was there), or over the window if it is critical and has not been acknowledged. */
    fun report(state: WarningState, warning: Warning, nowMs: Long): WarningState = when {
        warning.severity != "critical" -> state.copy(banner = BannerWarning(warning, nowMs))
        warning.kind in state.acknowledged -> state.copy(banner = BannerWarning(warning, nowMs))
        else -> state.copy(critical = warning)
    }

    /**
     * The critical warning's OK: it comes down, and its kind is remembered so the same one cannot put it straight back. It does not go to the banner
     * as well: the user has just read it and said so, and a later report of the condition does.
     */
    fun acknowledge(state: WarningState): WarningState {
        val kind = state.critical?.kind ?: return state
        return state.copy(critical = null, acknowledged = state.acknowledged + kind)
    }

    fun dismissBanner(state: WarningState): WarningState = state.copy(banner = null)

    /** [banner]'s time is up: it comes down, unless something replaced it in the meantime. */
    fun expire(state: WarningState, banner: BannerWarning): WarningState = if (state.banner == banner) state.copy(banner = null) else state

    /** The sequence was closed: a condition acknowledged about it is not acknowledged about the next, and a banner about it is not still up. */
    fun reset(state: WarningState): WarningState = WarningState(critical = state.critical)
}
