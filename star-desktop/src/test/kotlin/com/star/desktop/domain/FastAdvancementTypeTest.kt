package com.star.desktop.domain

import com.star.desktop.i18n.Strings
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class FastAdvancementTypeTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    @Test fun everyStrategyHasANameAndADescriptionInTheCatalogue() {
        for (t in FastAdvancementType.entries) {
            assertTrue(!t.label.startsWith("fast_advancement."), "${t.name}: ${t.label}")
            assertTrue(!t.description(20).startsWith("ui."), "${t.name}: ${t.description(20)}")
        }
    }

    @Test fun theNormalStrategyQuotesHowFarItMoves() {
        assertEquals("Fast Forward and Reverse move by 35 frames", FastAdvancementType.NORMAL.description(35))
        assertEquals("Normal", FastAdvancementType.NORMAL.label)
    }

    @Test fun theOtherStrategiesDoNotMentionAnAmount() {
        assertEquals(FastAdvancementType.SKIP_EMPTIES.description(5), FastAdvancementType.SKIP_EMPTIES.description(50))
    }
}
