package com.star.desktop.domain

import com.star.desktop.i18n.Strings
import com.star.proto.KeypointDivisorAdvice
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class KeypointDivisorTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private fun advice(reduce: Boolean, available: Boolean = true) = KeypointDivisorAdvice.newBuilder()
        .setAvailable(available).setReduceRecommended(reduce).setRecommendedDivisor(if (reduce) 1.5 else 1.0)
        .setImagePixels(42_400_000).setThresholdPixels(12_900_000).setFullResolutionConcurrency(10).setFrameConcurrency(36)
        .setPhysicalMemoryBytes(128L * 1024 * 1024 * 1024).build()

    @Test fun theValueIsAppliedAsItIsTypedWhileItIsANumberFromOneToEight() {
        assertEquals(1.5, KeypointDivisor.parse("1.5"))
        assertEquals(1.0, KeypointDivisor.parse("1"))
        assertEquals(8.0, KeypointDivisor.parse("8"), "8 is allowed, like the advanced panel")
        assertEquals(1.0, KeypointDivisor.parse("1."), "a prefix of a number being typed is a number")
        assertNull(KeypointDivisor.parse(""))
        assertNull(KeypointDivisor.parse("."))
        assertNull(KeypointDivisor.parse("0.5"), "less than full size is not a choice")
        assertNull(KeypointDivisor.parse("8.1"))
        assertNull(KeypointDivisor.parse("0"))
        assertNull(KeypointDivisor.parse("1.2.3"))
    }

    @Test fun strayCharactersAreIgnoredLikeTheMacField() {
        assertEquals(2.0, KeypointDivisor.parse(" 2x "))
    }

    @Test fun valuesAreShownWithoutTrailingZeros() {
        assertEquals("1", KeypointDivisor.format(1.0))
        assertEquals("1.5", KeypointDivisor.format(1.5))
        assertEquals("1.75", KeypointDivisor.format(1.75))
        assertEquals("2", KeypointDivisor.format(2.0))
        assertEquals("8", KeypointDivisor.format(8.0))
        assertEquals("1.33333", KeypointDivisor.format(4.0 / 3.0), "six significant digits, like %g")
    }

    @Test fun aPresetMatchesTheValueThatCameBackFromTheConfigToTwoDecimals() {
        assertTrue(KeypointDivisor.matches(1.5, 1.5004))
        assertFalse(KeypointDivisor.matches(1.5, 1.51))
    }

    @Test fun theBadgeIsOnlyOnTheRecommendedPresetOfAMachineThatNeedsOne() {
        val needs = advice(reduce = true)
        assertTrue(KeypointDivisor.isRecommended(needs, 1.5))
        assertFalse(KeypointDivisor.isRecommended(needs, 1.0))
        assertFalse(KeypointDivisor.isRecommended(needs, 2.0))
        assertFalse(KeypointDivisor.isRecommended(advice(reduce = false), 1.0), "nothing is recommended for a machine that copes")
        assertFalse(KeypointDivisor.isRecommended(null, 1.5))
    }

    @Test fun summaryLabelNamesOnlyThePresets() {
        assertEquals("1 \u2014 Best quality", KeypointDivisor.summaryLabel(1.0))
        assertEquals("1.5 \u2014 Best balance", KeypointDivisor.summaryLabel(1.5))
        assertEquals("2 \u2014 Fastest", KeypointDivisor.summaryLabel(2.0))
        assertEquals("1.5 \u2014 Best balance", KeypointDivisor.summaryLabel(1.5004), "a value that round-tripped through the config still names its preset")
        assertEquals("3", KeypointDivisor.summaryLabel(3.0))
        assertEquals("1.25", KeypointDivisor.summaryLabel(1.25))
    }

    @Test fun cancelKeepsOriginalUpdateCommitsDraft() {
        val picked = KeypointDivisorDraft(1.0)
        picked.choose(2.0)
        assertEquals(2.0, picked.committed())
        assertEquals(1.0, picked.cancelled(), "cancel leaves the value the modal opened with")

        val typed = KeypointDivisorDraft(1.5)
        typed.typed("3")
        typed.typed("3.")
        typed.typed("3.7")
        assertEquals(3.7, typed.committed(), "a typed custom value survives Update")
        assertEquals(1.5, typed.cancelled())

        val junk = KeypointDivisorDraft(2.0)
        junk.typed("")
        junk.typed("9")
        assertEquals(2.0, junk.committed(), "text that is not a value leaves the draft alone")
    }

    @Test fun warnsFromFourUp() {
        assertFalse(KeypointDivisor.isTooHigh(3.99))
        assertTrue(KeypointDivisor.isTooHigh(4.0))
        assertTrue(KeypointDivisor.isTooHigh(8.0))
    }

    @Test fun theExplanationQuotesTheMachinesOwnNumbers() {
        val text = KeypointDivisor.explanation(advice(reduce = true))
        assertTrue("42.4" in text && "128GB" in text && "10" in text && "36" in text && "12.9" in text, text)
        assertFalse("{0}" in text || "{4}" in text, "every placeholder was filled: $text")
    }

    @Test fun aMachineThatCopesIsToldThereIsNothingToChange() {
        val text = KeypointDivisor.explanation(advice(reduce = false))
        assertTrue("42.4" in text && "128GB" in text, text)
        assertEquals(KeypointDivisor.explanation(advice(reduce = false)), text)
        assertFalse(text == KeypointDivisor.explanation(advice(reduce = true)))
    }

    @Test fun withoutAFrameSizeOnlyTheTradeIsDescribed() {
        val without = KeypointDivisor.explanation(null)
        assertEquals(without, KeypointDivisor.explanation(advice(reduce = true, available = false)))
        assertTrue(without.endsWith(com.star.desktop.i18n.localized("ui.keypoint_no_numbers")))
    }

    @Test fun everyPresetHasItsWordsInTheCatalogue() {
        for (p in KeypointDivisor.presets) {
            assertFalse(com.star.desktop.i18n.localized(p.nameKey) == p.nameKey)
            assertFalse(com.star.desktop.i18n.localized(p.blurbKey) == p.blurbKey)
        }
    }
}
