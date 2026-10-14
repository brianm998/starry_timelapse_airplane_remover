package com.star.desktop.ui.sequence.edit

import com.star.desktop.domain.ToolType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The cursor over a group says what a click will do. */
class ToolCursorsTest {
    /** Remove sets "remove" even on a group already removed, so its cursor must not be the keep one (it used to toggle's). */
    @Test fun removeAlwaysShowsTheRemoveCursor() {
        for (willRemove in listOf(true, false, null)) {
            assertEquals("remove", ToolCursors.groupCursorBase(ToolType.REMOVE, willRemove), "willRemove=$willRemove")
        }
    }

    @Test fun keepAlwaysShowsTheKeepCursor() {
        for (willRemove in listOf(true, false, null)) {
            assertEquals("keep", ToolCursors.groupCursorBase(ToolType.KEEP, willRemove), "willRemove=$willRemove")
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
