package com.star.desktop.ui.dialogs

import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import com.star.desktop.ui.components.StarArt
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/** The first startup questions answer with pictures; the tag stays on the clickable and the word stays under the picture. */
class StartupPictureChoicesTest {
    @AfterTest fun reset() = Strings.setOverride(null)

    private fun check(rows: List<StartupPictureChoice>, expected: List<List<Any>>) {
        Strings.setOverride("en")
        assertEquals(expected.size, rows.size)
        for ((row, want) in rows.zip(expected)) {
            assertEquals(want[0], row.tag)
            assertEquals(want[1], row.art)
            assertEquals(want[2], localized(row.labelKey))
            assertNotNull(StarArt::class.java.classLoader.getResource(row.art.resourcePath), "${row.art.resourcePath} is missing")
        }
    }

    @Test fun horizonQuestionPictures() = check(HORIZON_CHOICES, listOf(
        listOf("startup.horizon.no", StarArt.ART_SKY_ONLY, "No"),
        listOf("startup.horizon.yes", StarArt.ART_SKY_AND_GROUND, "Yes"),
    ))

    @Test fun cameraQuestionPictures() = check(CAMERA_CHOICES, listOf(
        listOf("startup.moving.static", StarArt.ART_CAMERA_STATIC, "Static"),
        listOf("startup.moving.moving", StarArt.ART_CAMERA_MOVING, "Moving"),
    ))

    @Test fun horizonSelectionPictures() = check(SELECT_HORIZON_CHOICES, listOf(
        listOf("startup.selecthorizon.no", StarArt.ART_HORIZON_AUTO, "No"),
        listOf("startup.selecthorizon.yes", StarArt.ART_HORIZON_BRUSH, "Yes"),
    ))
}
