package com.star.desktop.domain

import com.star.desktop.domain.ClickRules.GroupClick
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ClickRulesTest {
    @Test fun aClickOnAGroupAppliesTheToolByDefault() {
        for (tool in listOf(ToolType.REMOVE, ToolType.KEEP, ToolType.RAZOR, ToolType.SHOVEL, ToolType.REMOVE_FROM_TRASH)) {
            assertEquals(GroupClick.APPLY_TOOL, ClickRules.groupClick(tool, multiChoice = false, decided = true), "$tool")
        }
    }

    /** E2 of the parity plan: with the switch off the Multi tool's click toggles, as in the macOS app; it was always the sheet here. */
    @Test fun theMultiToolWithTheSwitchOffTogglesLikeAnyOther() {
        assertEquals(GroupClick.APPLY_TOOL, ClickRules.groupClick(ToolType.MULTI, multiChoice = false, decided = false))
        assertEquals(GroupClick.APPLY_TOOL, ClickRules.groupClick(ToolType.MULTI, multiChoice = false, decided = true))
    }

    @Test fun theMultiToolWithTheSwitchOnOpensTheSheetOnADecidedGroup() {
        assertEquals(GroupClick.OPEN_MULTI_CHOICE, ClickRules.groupClick(ToolType.MULTI, multiChoice = true, decided = true))
        assertEquals(GroupClick.APPLY_TOOL, ClickRules.groupClick(ToolType.MULTI, multiChoice = true, decided = false))
    }

    /** The switch: any tool, but only on a group that has a decision. */
    @Test fun withMultiChoiceOnADecidedGroupOpensTheSheetWhateverTheTool() {
        for (tool in listOf(ToolType.REMOVE, ToolType.KEEP, ToolType.RAZOR, ToolType.SHOVEL, ToolType.REMOVE_FROM_TRASH)) {
            assertEquals(GroupClick.OPEN_MULTI_CHOICE, ClickRules.groupClick(tool, multiChoice = true, decided = true), "$tool")
            assertEquals(GroupClick.APPLY_TOOL, ClickRules.groupClick(tool, multiChoice = true, decided = false), "$tool undecided")
        }
    }

    /** macOS looks at the trash and information tools before the switch. */
    @Test fun theTrashAndInformationToolsKeepTheirMeaning() {
        assertEquals(GroupClick.APPLY_TOOL, ClickRules.groupClick(ToolType.TRASH, multiChoice = true, decided = true))
        assertEquals(GroupClick.APPLY_TOOL, ClickRules.groupClick(ToolType.INFORMATION, multiChoice = true, decided = true))
    }

    private val first = ClickRules.EmptyClick(timeMillis = 1000, x = 100f, y = 100f)

    @Test fun aSecondClickSoonAndNearbyIsADoubleClick() {
        assertTrue(ClickRules.completesDoubleClick(first, 1200, 103f, 98f, timeoutMillis = 300, slop = 8f))
    }

    @Test fun aSecondClickTooLateIsNot() {
        assertFalse(ClickRules.completesDoubleClick(first, 1301, 100f, 100f, timeoutMillis = 300, slop = 8f))
    }

    @Test fun aSecondClickElsewhereIsNot() {
        assertFalse(ClickRules.completesDoubleClick(first, 1100, 120f, 100f, timeoutMillis = 300, slop = 8f))
        assertFalse(ClickRules.completesDoubleClick(first, 1100, 100f, 90f, timeoutMillis = 300, slop = 8f))
    }

    @Test fun thereIsNoDoubleClickWithoutAFirstClick() {
        assertFalse(ClickRules.completesDoubleClick(null, 1100, 100f, 100f, timeoutMillis = 300, slop = 8f))
    }

    @Test fun aClockThatWentBackwardsIsNotADoubleClick() {
        assertFalse(ClickRules.completesDoubleClick(first, 900, 100f, 100f, timeoutMillis = 300, slop = 8f))
    }
}
