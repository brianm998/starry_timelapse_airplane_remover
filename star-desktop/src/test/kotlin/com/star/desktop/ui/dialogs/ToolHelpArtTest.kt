package com.star.desktop.ui.dialogs

import com.star.desktop.domain.ToolType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** Every selectable tool shows its own before-and-after diagram in the help. */
class ToolHelpArtTest {
    @Test fun everyToolHasItsDiagram() {
        val arts = ToolType.selectable.map { assertNotNull(toolHelpArt(it), "$it has no help art") }
        assertEquals(arts.size, arts.toSet().size, "a diagram is shared")
        assertEquals(8, arts.size)
        assertNull(toolHelpArt(ToolType.NONE))
    }
}
