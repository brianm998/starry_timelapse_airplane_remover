package com.star.desktop.domain

import com.star.desktop.i18n.Strings
import com.star.proto.StepProgress
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Q5/P9: the "Limited by" line under Use of this Mac, from the step report's `limited_by` and `resources_sampled`. */
class ResourceStatusTest {
    @AfterTest fun reset() = Strings.setOverride(null)

    private fun report(sampled: Boolean, limitedBy: String = "") =
        StepProgress.newBuilder().setResourcesSampled(sampled).setLimitedBy(limitedBy).build()

    @Test fun noLineWithoutARunOrBeforeTheFirstSample() {
        assertNull(ResourceStatus.text(null))
        assertNull(ResourceStatus.text(report(sampled = false)))
        assertNull(ResourceStatus.text(report(sampled = false, limitedBy = "GPU")), "a verdict from a governor that has not sampled is not one")
    }

    @Test fun sampledAndNothingLimitsTheRun() {
        Strings.setOverride("en")
        assertEquals("Not limited by a resource", ResourceStatus.text(report(sampled = true)))
    }

    @Test fun sampledAndOneResourceHoldsItBack() {
        Strings.setOverride("en")
        assertEquals("Limited by: GPU", ResourceStatus.text(report(sampled = true, limitedBy = "GPU")))
        assertEquals("Limited by: disk /Volumes/rp", ResourceStatus.text(report(sampled = true, limitedBy = "disk /Volumes/rp")))
        Strings.setOverride("de")
        assertNotEquals("Limited by: GPU", ResourceStatus.text(report(sampled = true, limitedBy = "GPU")), "the sentence is the user's language")
    }

    @Test fun theModalAndThePanelShowIt() {
        val modal = listOf(File("src/main/kotlin/com/star/desktop/ui/dialogs/ProcessingModal.kt"), File("star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/ProcessingModal.kt")).first { it.isFile }.readText()
        val panel = listOf(File("src/main/kotlin/com/star/desktop/ui/sequence/RightPanel.kt"), File("star-desktop/src/main/kotlin/com/star/desktop/ui/sequence/RightPanel.kt")).first { it.isFile }.readText()
        assertTrue("ResourceProfileControl(app, com.star.desktop.domain.ResourceStatus.text(report))" in modal)
        assertTrue("ResourceProfileControl(app, com.star.desktop.domain.ResourceStatus.text(stepReport), stacked = true)" in panel)
    }
}
