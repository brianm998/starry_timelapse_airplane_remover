package com.star.desktop.ui.dialogs

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/** P8: the Alignment tab lists its rows in the order the gui's sheet does (`ProcessingSettingsView`'s `alignmentTab`). */
class AlignmentFieldOrderTest {
    @Test fun theRowsAreInTheGuisOrder() {
        // the gui's rows, by the catalogue key the desktop labels the same setting with
        val gui = File("../gui/star/ProcessingSettingsView.swift").takeIf { it.isFile } ?: File("gui/star/ProcessingSettingsView.swift")
        val source = gui.readText()
        val tab = source.substringAfter("private var alignmentTab: some View").substringBefore("private var horizonTab")
        val guiOrder = Regex("self\\.([A-Za-z]+View)").findAll(tab).map { it.groupValues[1] }.toList()
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
