package com.star.desktop.ui.dialogs

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/** P8: the alignment group lists its rows in the order the gui's sheet does (`ProcessingSettingsView`'s alignment `DisclosureGroup`). */
class AlignmentFieldOrderTest {
    @Test fun theRowsAreInTheGuisOrder() {
        // the gui's rows, by the catalogue key the desktop labels the same setting with
        val gui = File("../gui/star/ProcessingSettingsView.swift").takeIf { it.isFile } ?: File("gui/star/ProcessingSettingsView.swift")
        val source = gui.readText()
        val group = source.substringAfter("self.neighborFrameCountView").substringBefore("Text(localized(\"ui.alignment_settings\"))")
        val guiOrder = Regex("self\\.([A-Za-z]+View)").findAll("self.neighborFrameCountView$group").map { it.groupValues[1] }.toList()
        val byGuiView = mapOf(
            "neighborFrameCountView" to "ui.neighbor_frame_count",
            "staticNeighborFrameCountView" to "ui.static_neighbor_frame_count",
            "pixelThresholdView" to "ui.pixel_threshold",
            "alignmentMaxKeypointsView" to "ui.max_keypoints",
            "alignmentGroundHorizonExtensionView" to "ui.ground_horizon_extension",
            "alignmentSkyHorizonExtensionView" to "ui.sky_horizon_extension",
            "alignmentBaseImageDilateSizeView" to "ui.base_image_dilation_size",
            "alignmentBaseImageThresholdValueView" to "ui.base_image_threshold",
            "alignmentKeypointDivisorView" to "ui.keypoint_divisor",
            "allowEarthAlignmentView" to "ui.allow_earth_alignment",
            "alignmentWriteDebugImagesViewValueView" to "ui.write_debug_images",
            "homographySmoothingEpsilonView" to "ui.homography_smoothing",
        )
        assertEquals(byGuiView.keys.toList(), guiOrder, "the gui's alignment rows changed: update this table and the desktop's list")
        assertEquals(guiOrder.map { byGuiView.getValue(it) }, ALIGNMENT_FIELDS.map { it.labelKey })
    }
}
