package com.star.desktop.domain

import com.star.desktop.i18n.localized
import com.star.proto.KeypointDivisorAdvice
import java.math.BigDecimal
import java.math.MathContext
import java.util.Locale
import kotlin.math.abs

/**
 * The "Speed vs. Sharpness" choice on the last startup prompt (macOS `KeypointDivisorStartupView`): how much smaller than the frame the
 * alignment step looks for stars, which is the setting that decides whether a large sequence runs at a sensible speed or crawls.
 *
 * The choices and the rules for what is accepted live here so they can be tested; whether this machine needs one at all is the daemon's
 * answer ([KeypointDivisorAdvice], from StarCore). Deliberately free of the words keypoint, homography and descriptor in what the user reads.
 */
object KeypointDivisor {
    class Preset(val divisor: Double, val nameKey: String, val blurbKey: String)

    /**
     * The three offered values. 1.5 is StarCore's `Config.recommendedReducedKeypointDivisor`, which is what the daemon recommends
     * when it advises a reduction, so the preset it is badged on is always one of these.
     */
    val presets: List<Preset> = listOf(
        Preset(1.0, "ui.preset_best_quality", "ui.preset_best_quality_blurb"),
        Preset(1.5, "ui.preset_best_balance", "ui.preset_best_balance_blurb"),
        Preset(2.0, "ui.preset_fastest", "ui.preset_fastest_blurb"),
    )

    /** At or above this, say so. Not a limit: someone desperate for speed on a machine the footage does not fit may want it anyway. */
    const val TOO_HIGH = 4.0

    /** The largest value the field accepts: past here it is not a trade any more, it is a typo (inclusive, like the Advanced panel's field). */
    const val MAX = 8.0

    /** Compared with a tolerance because StarCore quantizes the divisor to two decimals for the feature files, so one that round-tripped differs a little. */
    fun matches(a: Double, b: Double): Boolean = abs(a - b) < 0.005

    fun isTooHigh(divisor: Double): Boolean = divisor >= TOO_HIGH

    /**
     * What the field holds as a value, or null while it is not one: the digits and points of [text], read as a number from 1 to [MAX].
     * Every prefix of a number being typed is itself a number, so this can be applied on every keystroke, which it has to be: Start
     * Processing is right below the field, and a value typed but not committed would be dropped when the button takes focus.
     */
    fun parse(text: String): Double? {
        val value = text.filter { it in '0'..'9' || it == '.' }.toDoubleOrNull() ?: return null
        return value.takeIf { it >= 1.0 && it <= MAX }
    }

    /** "1", "1.5", "1.75": no trailing zeros, because this text goes in a field the user then edits. */
    fun format(value: Double): String =
        BigDecimal(value).round(MathContext(6)).stripTrailingZeros().toPlainString()

    fun megapixels(pixels: Long): String = String.format(Locale.ROOT, "%.1f", pixels / 1_000_000.0)

    /** The machine's memory, as someone would say it out loud. */
    fun memory(bytes: Long): String = "${bytes / (1024L * 1024L * 1024L)}GB"

    /** Whether the badge goes on the preset with [divisor]: only when the machine needs a reduction, and then on the one the daemon names. */
    fun isRecommended(advice: KeypointDivisorAdvice?, divisor: Double): Boolean =
        advice != null && advice.available && advice.reduceRecommended && matches(advice.recommendedDivisor, divisor)

    /**
     * What the cleanup dialog's one-line summary says is in effect: "1 — Best quality", "1.5 — Best balance" or "2 — Fastest" for a
     * preset, and for any other value the bare number (no "divide by", no name: none of the three is what will run).
     */
    fun summaryLabel(divisor: Double): String {
        val preset = presets.firstOrNull { matches(divisor, it.divisor) } ?: return format(divisor)
        return format(preset.divisor) + " \u2014 " + localized(preset.nameKey)
    }

    /**
     * Two versions on purpose. Below the machine's crossover there is genuinely nothing to gain here, and saying so is more useful than
     * a recommendation; at or above it this is the setting that decides how the run goes, and the numbers that say why are the machine's own.
     * With no frame size yet there are no honest numbers to quote, so only the trade is described.
     */
    fun explanation(advice: KeypointDivisorAdvice?): String {
        val intro = localized("ui.keypoint_intro")
        if (advice == null || !advice.available) return intro + "\n\n" + localized("ui.keypoint_no_numbers")
        val frames = megapixels(advice.imagePixels)
        val ram = memory(advice.physicalMemoryBytes)
        return if (advice.reduceRecommended) {
            intro + "\n\n" + localized(
                "ui.keypoint_reduce_recommended", frames, ram, advice.fullResolutionConcurrency, advice.frameConcurrency, megapixels(advice.thresholdPixels),
            )
        } else {
            intro + "\n\n" + localized("ui.keypoint_no_change_needed", frames, ram)
        }
    }
}

/**
 * The value the Speed vs. Sharpness modal edits: a draft of [original], the value the modal opened with. Nothing reaches the session until
 * [committed] is applied (Update); [cancelled] is what Cancel leaves in place.
 */
class KeypointDivisorDraft(val original: Double) {
    var current: Double = original
        private set

    /** A preset picked (or any other value chosen outright). */
    fun choose(value: Double) { current = value }

    /** The custom field's text, applied on every keystroke like the field always was: text that is not (yet) a number leaves the draft alone. */
    fun typed(text: String) { KeypointDivisor.parse(text)?.let { current = it } }

    /** The value Update keeps: the draft, including a typed custom one. */
    fun committed(): Double = current

    /** The value Cancel keeps: the one the modal opened with. */
    fun cancelled(): Double = original
}
