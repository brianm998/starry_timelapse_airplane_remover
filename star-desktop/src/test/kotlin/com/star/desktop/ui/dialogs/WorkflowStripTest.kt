package com.star.desktop.ui.dialogs

import kotlin.test.Test
import kotlin.test.assertEquals

/** The How To tab's workflow strip (macOS `testWorkflowStripOrder`). */
class WorkflowStripTest {
    @Test fun stepsInOrder() {
        assertEquals(
            listOf("art_step_import", "art_step_horizon", "art_step_align", "art_step_merge", "art_step_review", "art_step_render"),
            WORKFLOW_STRIP_STEPS.map { it.slot },
        )
    }
}
