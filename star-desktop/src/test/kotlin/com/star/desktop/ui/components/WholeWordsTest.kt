package com.star.desktop.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.moveTo
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performMouseInput
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.star.desktop.domain.FastAdvancementType
import com.star.desktop.domain.StepRow
import com.star.desktop.domain.ToolType
import com.star.desktop.domain.ViewModes
import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import com.star.desktop.ui.dialogs.InfoType
import com.star.desktop.ui.dialogs.StepsView
import com.star.desktop.ui.dialogs.UnsupportedRow
import com.star.desktop.ui.dialogs.infoPickerWidth
import com.star.desktop.ui.dialogs.processingModalContentWidth
import com.star.desktop.ui.dialogs.rememberProcessingColumns
import com.star.desktop.ui.sequence.BulkButton
import com.star.desktop.ui.sequence.ChangeModeButton
import com.star.desktop.ui.sequence.HorizonKindRow
import com.star.desktop.ui.sequence.NeighborCountEditor
import com.star.desktop.ui.sequence.OnlyUnclassifiedRow
import com.star.desktop.ui.sequence.OpacitySlider
import com.star.desktop.ui.sequence.SwitchRow
import com.star.desktop.ui.sequence.ToolRow
import com.star.desktop.ui.sequence.ZoomHeader
import com.star.desktop.ui.sequence.grid.GridSwitchRow
import com.star.desktop.ui.sequence.grid.InfoRow
import com.star.desktop.ui.theme.StarColors
import com.star.desktop.ui.windows.BlobArgsHeader
import com.star.desktop.ui.windows.COLUMN_CHOOSER_WIDTH
import com.star.desktop.ui.windows.ColumnChooserRow
import com.star.desktop.ui.windows.ColumnChooserTop
import com.star.desktop.ui.windows.Header
import com.star.desktop.ui.windows.HoughHeader
import com.star.desktop.ui.windows.Toggle
import com.star.desktop.ui.windows.blobNameColumnWidth
import com.star.desktop.ui.windows.blobValueColumnWidth
import com.star.desktop.ui.windows.houghLineCellWidth
import com.star.desktop.ui.windows.outlierColumnWidths
import com.star.desktop.domain.OutlierTable
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** No Text in the client breaks inside a word at the least width its container is given, in English and in German (long compound words). */
@OptIn(ExperimentalTestApi::class)
class WholeWordsTest {
    @AfterTest fun systemLanguage() = Strings.setOverride(null)

    private fun assertNone(problems: List<String>) = assertTrue(problems.isEmpty(), problems.joinToString("\n"))

    private val types = listOf("horizon", "mergedHorizon", "starKeypoints", "earthKeypoints", "starHomography", "earthHomography", "horizonConsensus", "outliers", "merge")
    /** Every step, the first three finished and the rest part way. */
    private val steps = types.mapIndexed { i, type ->
        if (i < 3) StepRow(type, queued = 0, running = 0, done = 12, alreadyDone = 0) else StepRow(type, queued = 3, running = 2, done = 4, alreadyDone = 1)
    }

    /** The Processing modal's headers ("Queued", "Running", "Time left") and step names, in the modal as narrow as it is allowed to be. */
    @Test fun testProcessingModalColumnHeadersKeepWholeWords() {
        assertNone(wholeWordProblemsInEachLanguage({ processingModalContentWidth(rememberProcessingColumns(steps)) }) {
            StepsView(steps, hasReport = true, estimates = steps.associate { it.type to 9 * 3600.0 + 59 * 60 })
        })
    }

    /** The panels' widths less their padding: the right panel is 150dp (8dp padding), the left 220dp (12), the grid's left 160dp (12) and right 200dp (12). */
    private val rightPanel = 134.dp
    private val leftPanel = 196.dp
    private val gridLeftPanel = 136.dp
    private val gridRightPanel = 176.dp

    private fun check(width: Dp, content: @Composable () -> Unit) = assertNone(wholeWordProblemsInEachLanguage(width, content))

    @Test fun testNoLabelBreaksInsideAWordAtMinimumWidth() {
        val problems = ArrayList<String>()
        fun case(name: String, width: Dp, content: @Composable () -> Unit) {
            problems += wholeWordProblemsInEachLanguage(width, content).map { "$name: $it" }
        }
        val noop = {}
        val noopBool: (Boolean) -> Unit = {}

        // The right panel (150dp): the selective tools and the processing section.
        case("right panel tools", rightPanel) { Column { ToolType.selectable.forEach { ToolRow(it, selected = false, onClick = noop) } } }
        case("right panel switches", rightPanel) {
            Column {
                SwitchRow(localized("ui.multi_choice"), null, false, noopBool)
                SwitchRow(localized("ui.show_trash"), null, false, noopBool)
                OnlyUnclassifiedRow(false, noopBool)
                OpacitySlider(localized("ui.outlier_group_opacity"), "", 0.5f) {}
                OpacitySlider(localized("ui.trash_opacity"), "", 0.5f) {}
            }
        }
        case("right panel buttons", rightPanel) {
            Column {
                BulkButton(localized("ui.render_updates"), StarColors.blue) {}
                BulkButton(localized("ui.re_run_horizon_refinement"), StarColors.blue) {}
                BulkButton(localized("ui.paint_horizon_reference"), StarColors.blue) {}
                BulkButton(localized("ui.close_horizon_painter"), StarColors.red) {}
                ChangeModeButton(noop)
            }
        }
        case("right panel neighbours", rightPanel) {
            NeighborCountEditor("ui.slider.static_merge", "ui.slider.neighbors", 5, overridden = true, max = 20, frame = 0, onCommit = {}, onReset = noop)
        }

        // The left panel (220dp): the display section.
        case("left panel switches", leftPanel) {
            Column {
                SwitchRow(localized("ui.show_horizon_line"), null, false, noopBool)
                SwitchRow(localized("ui.show_full_resolution"), null, false, noopBool)
                OpacitySlider(localized("ui.frame_opacity"), "", 0.5f) {}
                ZoomHeader("1", valid = true, onChange = {}, commit = noop, revert = noop)
            }
        }
        case("left panel horizon kinds", leftPanel - 16.dp) {
            Column { com.star.desktop.ui.components.HorizonLineKinds.all.forEach { HorizonKindRow(it, false, true, noopBool) } }
        }
        case("left panel pickers", leftPanel) {
            Column {
                VerticalStarPicker(ViewModes.all, ViewModes.all.first(), { ViewModes.longName(it) }, {}, Modifier.width(leftPanel))
                VerticalStarPicker(FastAdvancementType.entries, FastAdvancementType.NORMAL, { it.label }, {}, Modifier.width(leftPanel))
            }
        }
        case("right panel fast advancement picker", rightPanel) {
            VerticalStarPicker(FastAdvancementType.entries, FastAdvancementType.NORMAL, { it.label }, {}, Modifier.width(rightPanel))
        }

        // The grid's panels: left 160dp, right 200dp.
        case("grid left picker", gridLeftPanel) { VerticalStarPicker(ViewModes.all, ViewModes.all.first(), { ViewModes.longName(it) }, {}, Modifier.width(gridLeftPanel)) }
        case("grid right switches", gridRightPanel) {
            Column {
                GridSwitchRow(localized("ui.show_horizon_lines"), true, noopBool)
                GridSwitchRow(localized("ui.show_filmstrip"), true, noopBool)
            }
        }
        case("grid right horizon kinds", gridRightPanel - 16.dp) {
            Column { com.star.desktop.ui.components.HorizonLineKinds.all.forEach { HorizonKindRow(it, false, true, noopBool) } }
        }
        case("grid right info rows", gridRightPanel) {
            Column {
                for (key in listOf("ui.index", "ui.file", "ui.state", "ui.positive", "ui.negative", "ui.undecided", "ui.trash", "ui.mode", "ui.horizon")) InfoRow(localized(key), "12")
                InfoRow(localized("ui.file"), "IMG_20261103_232145_000123_longer_than_the_panel.tif")
            }
        }

        // The windows: the alignment window's 190dp column, the outlier tables, the blob parameter table.
        case("alignment toggles", 190.dp) {
            Column {
                for (key in listOf("ui.star_deviation", "ui.star_keypoints", "ui.earth_deviation", "ui.earth_keypoints")) Toggle(localized(key), true, noopBool)
                OffsetLegend(listOf(-3, -2, -1, 1, 2, 3), Modifier.width(190.dp))
            }
        }
        case("outlier headers", 640.dp) {
            val visible = OutlierTable.columns
            val widths = outlierColumnWidths(visible)
            androidx.compose.foundation.layout.Row {
                Header(localized("ui.remove"), OutlierTable.DECISION, OutlierTable.defaultSort, widths.decision) {}
                Header(localized("ui.size"), OutlierTable.SIZE, OutlierTable.defaultSort, widths.size) {}
                for (c in visible) Header(localized(c.labelKey), c.key, OutlierTable.defaultSort, widths.column) {}
            }
        }
        case("outlier column chooser", COLUMN_CHOOSER_WIDTH - 8.dp) {
            Column {
                ColumnChooserTop({}, {}, {})
                OutlierTable.columns.forEach { ColumnChooserRow(localized(it.labelKey), true, noopBool) }
            }
        }
        case("hough line headers", 900.dp) {
            val cell = houghLineCellWidth()
            androidx.compose.foundation.layout.Row {
                for (key in listOf("ui.intensity_score", "ui.pixel_score", "ui.theta", "ui.rho", "ui.votes", "ui.border")) HoughHeader(localized(key), true, cell) {}
            }
        }
        case("blob parameter table", 760.dp) {
            val names = listOf("minimumAreaThreshold", "maximumNeighborDistanceThreshold")
            BlobArgsHeader(blobNameColumnWidth(names), blobValueColumnWidth())
            Box(Modifier.width(blobNameColumnWidth(names))) { androidx.compose.material3.Text(names[1], maxLines = 1, softWrap = false) }
        }

        // The dialogs: the information dialog's picker column, and a settings row that needs a newer engine.
        case("info picker", 400.dp) {
            VerticalStarPicker(InfoType.entries.toList(), InfoType.entries.first(), { localized(it.labelKey) }, {}, Modifier.width(infoPickerWidth()))
        }
        case("unsupported row", 420.dp) {
            UnsupportedRow(localized("ui.close_horizon_painter"), "0.11.2")
        }
        assertNone(problems)
    }

    /** An ellipsized value keeps its whole text: hovering the grid panel's file name shows it in a tooltip. */
    @Test fun testEllipsizedValuesHaveATooltip() = runComposeUiTest {
        Strings.setOverride("en")
        val name = "IMG_20261103_232145_000123_longer_than_the_panel.tif"
        setContent { com.star.desktop.ui.theme.StarTheme { Box(Modifier.width(gridRightPanel)) { InfoRow("File", name) } } }
        waitForIdle()
        onAllNodesWithText(name, useUnmergedTree = true).assertCountEquals(1)
        onNodeWithText(name, useUnmergedTree = true).performMouseInput { moveTo(center) }
        mainClock.advanceTimeBy(1000)
        waitForIdle()
        onAllNodesWithText(name, useUnmergedTree = true).assertCountEquals(2)
    }
}
