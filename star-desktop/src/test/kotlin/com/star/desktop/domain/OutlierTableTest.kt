package com.star.desktop.domain

import com.star.desktop.domain.OutlierTable.Row
import com.star.desktop.domain.OutlierTable.Selection
import com.star.desktop.domain.OutlierTable.Sort
import com.star.desktop.i18n.Strings
import com.star.proto.RemoveReason
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class OutlierTableTest {
    @BeforeTest fun english() = Strings.setOverride("en")
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private fun row(id: Int, size: Long = 100, vararg features: Pair<String, Double>, classification: Double = 0.0) =
        Row(id, size, features.toMap(), classification)

    // ---- columns ----

    /** macOS offers 35 optional columns: the id, the 33 decision-tree values it shows, and the classifier's score. */
    @Test fun thereAreThirtyFiveOptionalColumnsEachWithAName() {
        assertEquals(35, OutlierTable.columns.size)
        assertEquals(35, OutlierTable.columns.map { it.key }.toSet().size)
        for (c in OutlierTable.columns) assertTrue(!Strings.get(c.labelKey).startsWith("ui."), "${c.key}: ${c.labelKey} is not in the catalogue")
    }

    @Test fun theDefaultsAreMacOSs() {
        val off = OutlierTable.columns.filter { !it.defaultVisible }.map { it.key }.toSet()
        assertEquals(setOf("name", "centerX", "centerY", "minX", "minY", "maxX", "maxY"), off)
        assertEquals(35 - 7, OutlierTable.defaultColumns.size)
    }

    @Test fun visibleColumnsFollowTheChoiceInTableOrder() {
        assertEquals(listOf("width", "classificationScore"), OutlierTable.visible(listOf("classificationScore", "width", "gone")).map { it.key })
        assertEquals(OutlierTable.defaultColumns, OutlierTable.visible(null).map { it.key }.toSet())
        assertEquals(emptyList(), OutlierTable.visible(emptyList()))
    }

    // ---- sorting ----

    @Test fun clickingAHeaderSortsByItThenTurnsTheOrderRound() {
        val first = OutlierTable.clicked(OutlierTable.defaultSort, "width")
        assertEquals(Sort("width", ascending = true), first)
        assertEquals(Sort("width", ascending = false), OutlierTable.clicked(first, "width"))
        assertEquals(Sort("size", ascending = true), OutlierTable.clicked(first, "size"))
    }

    @Test fun rowsSortBySizeAndByAFeature() {
        val rows = listOf(row(1, 50, "width" to 9.0), row(2, 300, "width" to 1.0), row(3, 120, "width" to 5.0))
        val undecided = { _: Int -> RemoveReason.RR_UNDECIDED }
        assertEquals(listOf(2, 3, 1), OutlierTable.sorted(rows, Sort("size", false), undecided).map { it.groupId })
        assertEquals(listOf(1, 3, 2), OutlierTable.sorted(rows, Sort("size", true), undecided).map { it.groupId })
        assertEquals(listOf(2, 3, 1), OutlierTable.sorted(rows, Sort("width", true), undecided).map { it.groupId })
        assertEquals(listOf(1, 3, 2), OutlierTable.sorted(rows, Sort("width", false), undecided).map { it.groupId })
    }

    @Test fun rowsSortByTheClassifiersScoreAndByTheId() {
        val rows = listOf(row(5, classification = -0.5), row(3, classification = 0.9), row(8, classification = 0.1))
        val undecided = { _: Int -> RemoveReason.RR_UNDECIDED }
        assertEquals(listOf(3, 8, 5), OutlierTable.sorted(rows, Sort("classificationScore", false), undecided).map { it.groupId })
        assertEquals(listOf(8, 5, 3), OutlierTable.sorted(rows, Sort("name", false), undecided).map { it.groupId })
    }

    /** macOS's `WillRemoveType` order: to be removed, then kept, then undecided; and the decision is whatever it is now. */
    @Test fun rowsSortByTheirCurrentDecision() {
        val rows = listOf(row(1), row(2), row(3), row(4))
        val decisions = mapOf(
            1 to RemoveReason.RR_USER_KEEP, 2 to RemoveReason.RR_UNDECIDED,
            3 to RemoveReason.RR_CLASSIFIER_REMOVE, 4 to RemoveReason.RR_CLASSIFIER_KEEP,
        )
        val order = OutlierTable.sorted(rows, Sort(OutlierTable.DECISION, true)) { decisions.getValue(it) }.map { it.groupId }
        assertEquals(listOf(3, 1, 4, 2), order)
    }

    @Test fun tiesKeepTheOrderOfTheIds() {
        val rows = listOf(row(9, 10), row(2, 10), row(5, 10))
        val undecided = { _: Int -> RemoveReason.RR_UNDECIDED }
        assertEquals(listOf(2, 5, 9), OutlierTable.sorted(rows, Sort("size", true), undecided).map { it.groupId })
        assertEquals(listOf(2, 5, 9), OutlierTable.sorted(rows, Sort("size", false), undecided).map { it.groupId })
    }

    // ---- selection ----

    private val order = listOf(10, 20, 30, 40, 50)

    @Test fun aPlainClickSelectsThatRowAlone() {
        val one = OutlierTable.click(Selection(), order, 20, toggle = false, extend = false)
        assertEquals(Selection(setOf(20), 20), one)
        assertEquals(Selection(setOf(40), 40), OutlierTable.click(one, order, 40, toggle = false, extend = false))
    }

    @Test fun aToggleClickAddsAndRemovesARow() {
        val a = OutlierTable.click(Selection(setOf(20), 20), order, 40, toggle = true, extend = false)
        assertEquals(setOf(20, 40), a.ids)
        assertEquals(setOf(20), OutlierTable.click(a, order, 40, toggle = true, extend = false).ids)
    }

    @Test fun aShiftClickSelectsTheRowsBetween() {
        val start = Selection(setOf(20), 20)
        assertEquals(setOf(20, 30, 40), OutlierTable.click(start, order, 40, toggle = false, extend = true).ids)
        assertEquals(setOf(10, 20), OutlierTable.click(start, order, 10, toggle = false, extend = true).ids)
        // the anchor stays, so a second shift-click moves the end of the range
        val range = OutlierTable.click(start, order, 40, toggle = false, extend = true)
        assertEquals(setOf(20, 30), OutlierTable.click(range, order, 30, toggle = false, extend = true).ids)
    }

    @Test fun aShiftToggleClickAddsTheRangeToWhatIsSelected() {
        val start = Selection(setOf(10, 30), 30)
        assertEquals(setOf(10, 30, 40, 50), OutlierTable.click(start, order, 50, toggle = true, extend = true).ids)
    }

    @Test fun aShiftClickWithNoAnchorIsAPlainClick() {
        assertEquals(Selection(setOf(30), 30), OutlierTable.click(Selection(), order, 30, toggle = false, extend = true))
    }

    // ---- numbers ----

    @Test fun valuesAreWrittenLikeCsPercentG() {
        assertEquals("0", OutlierTable.formatG(0.0))
        assertEquals("100", OutlierTable.formatG(100.0))
        assertEquals("0.5", OutlierTable.formatG(0.5))
        assertEquals("0.1", OutlierTable.formatG(0.1))
        assertEquals("1234.6", OutlierTable.formatG(1234.5678))
        assertEquals("-3.1416", OutlierTable.formatG(-Math.PI))
        assertEquals("0.0001234", OutlierTable.formatG(0.0001234))
        assertEquals("1.234e-05", OutlierTable.formatG(0.00001234))
        assertEquals("1.2346e+05", OutlierTable.formatG(123456.0))
        assertEquals("1e+10", OutlierTable.formatG(1e10))
        assertEquals("99999", OutlierTable.formatG(99999.0))
        assertEquals("1e+05", OutlierTable.formatG(99999.9))
        assertEquals("nan", OutlierTable.formatG(Double.NaN))
        assertEquals("-inf", OutlierTable.formatG(Double.NEGATIVE_INFINITY))
    }
}
