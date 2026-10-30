package com.star.desktop.ui.sequence.edit

import com.star.desktop.domain.ToolType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The cursor over a group says what a click will do. */
class ToolCursorsTest {
    /** E1 of the parity plan: Remove and Keep toggle on a click, as in the macOS app, so their cursor shows what the click will do. */
    @Test fun removeAndKeepShowTheOppositeOfTheCurrentDecision() {
        for (tool in listOf(ToolType.REMOVE, ToolType.KEEP, ToolType.MULTI)) {
            assertEquals("keep", ToolCursors.groupCursorBase(tool, true), "$tool on a removed group")
            assertEquals("remove", ToolCursors.groupCursorBase(tool, false), "$tool on a kept group")
            assertEquals("remove", ToolCursors.groupCursorBase(tool, null), "$tool on an undecided group")
        }
    }

    @Test fun theToolsThatToggleShowTheOppositeOfTheCurrentDecision() {
        assertEquals("keep", ToolCursors.groupCursorBase(ToolType.RAZOR, true))
        assertEquals("remove", ToolCursors.groupCursorBase(ToolType.RAZOR, false))
        assertEquals("remove", ToolCursors.groupCursorBase(ToolType.SHOVEL, null))
    }

    @Test fun trashAndInformationHaveTheirOwnAndNoneIsTheArrow() {
        assertEquals("delete_trash", ToolCursors.groupCursorBase(ToolType.TRASH, true))
        assertEquals("info", ToolCursors.groupCursorBase(ToolType.INFORMATION, false))
        assertNull(ToolCursors.groupCursorBase(ToolType.NONE, true))
    }
}
