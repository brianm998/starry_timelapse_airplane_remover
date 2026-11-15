package com.star.desktop.ui.dialogs

import com.google.gson.JsonParser
import com.star.desktop.i18n.Strings
import com.star.desktop.i18n.localized
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * The settings sheet is tabs: Cleaning (which it opens on), GPU Usage, Alignment, Horizon and Memory, each with a scroll view of its own, and no
 * expert button. The gui's are the same tabs (`gherkin/ui/vectors/constants.json`, `settingsTabs`, which its `SharedConstantsTests` reads too); the
 * layout, which Compose has no window test host for (§6.3), is read from the source, and `SettingsSheetLiveApplyTest` drives it for real.
 */
class SettingsTabsTest {
    @AfterTest fun reset() = Strings.setOverride(null)

    private fun find(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()

    private val dialog = find("star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/ProcessingSettingsDialog.kt")
    private val rule = JsonParser.parseString(find("gherkin/ui/vectors/constants.json")).asJsonObject.getAsJsonObject("settingsTabs")

    @Test fun theTabsAreTheGuisInTheSameOrderOpeningOnTheSameOne() {
        assertEquals(rule.getAsJsonArray("tabs").map { it.asString }, SettingsTab.entries.map { it.id })
        assertEquals(rule.get("default").asString, SettingsTab.FIRST.id, "the sheet opens on the first tab")
        assertEquals(SettingsTab.entries.first(), SettingsTab.FIRST)
        assertTrue("mutableStateOf(SettingsTab.FIRST)" in dialog, "the sheet does not open on the first tab")
    }

    @Test fun eachTabIsNamedInTheCatalogueAndFoundByItsId() {
        for (tab in SettingsTab.entries) {
            assertEquals("settings_tab.${tab.id}", tab.titleKey)
            assertEquals("settings.tab.${tab.id}", tab.testTag)
            Strings.setOverride("en")
            val english = localized(tab.titleKey)
            assertNotEquals(tab.titleKey, english, "${tab.id} is missing from the catalogue")
            Strings.setOverride("de")
            assertNotEquals(english, localized(tab.titleKey), "${tab.id} is English in German")
        }
    }

    @Test fun theNamesAreTheOnesAskedFor() {
        Strings.setOverride("en")
        assertEquals(listOf("Cleaning", "GPU Usage", "Alignment", "Horizon", "Memory"), SettingsTab.entries.map { localized(it.titleKey) })
    }

    @Test fun everySettingIsOnATabAndNoneIsBehindAnExpertButton() {
        assertFalse("showExpert" in dialog || "setShowExpertSettings" in dialog, "an expert toggle is left in the sheet")
        assertFalse("ExpertSettings" in find("star-desktop/src/main/kotlin/com/star/desktop/ui/app/AppViewModel.kt"), "the view model still remembers one")
        fun branch(tab: String, next: String?) =
            dialog.substringAfter("SettingsTab.$tab ->").let { if (next == null) it.substringBefore("VerticalScrollbar(") else it.substringBefore("SettingsTab.$next ->") }
        // Cleaning: the cloud-aware merge, Selective Auto Clean and the selective processing mode are on it with the scene, the camera and the method.
        val cleaning = branch("CLEANING", "GPU")
        for (part in listOf("MERGE_FIELDS", "infoId = \"autoselective\"", "infoId = \"detection\"", "infoId = \"scene\"", "infoId = \"camera\"", "infoId = \"clean\""))
            assertTrue(part in cleaning, "$part is not on the Cleaning tab")
        assertTrue("GpuGroup(" in branch("GPU", "ALIGNMENT"))
        assertTrue("ALIGNMENT_FIELDS" in branch("ALIGNMENT", "HORIZON"))
        assertTrue("HORIZON_FIELDS" in branch("HORIZON", "MEMORY"))
        assertTrue("MEMORY_FIELDS" in branch("MEMORY", null))
        // The GPU toggles are what GpuGroup lists, so a field added to that list shows on the tab.
        assertTrue("PERFORMANCE_FIELDS.forEach" in dialog)
    }

    @Test fun eachTabScrollsByItself() {
        // A tab taller than the window is reached by scrolling it; one opened after another was scrolled starts at its top.
        assertTrue("key(tab) {" in dialog && "verticalScroll(scroll)" in dialog && "VerticalScrollbar(rememberScrollbarAdapter(scroll)" in dialog)
        // The card has a height of its own, and the buttons are outside what scrolls: a sheet that grew with its tab would have nothing to scroll.
        assertTrue(".size(size)" in dialog)
        val buttons = dialog.indexOf("settings.process")
        assertTrue(buttons > dialog.indexOf("VerticalScrollbar(rememberScrollbarAdapter(scroll)"), "Process Now is inside the scroll view")
    }

    @Test fun theQuestionAboutReprocessingIsOverTheWindowNotInTheCard() {
        // The card is a fixed height with no room for a card of its own, so the question is a sibling of it.
        assertTrue(dialog.indexOf("if (askUpdate) {") > dialog.indexOf("SheetCard(sheetSize) {"))
        val card = dialog.substringAfter("SheetCard(sheetSize) {\n        // The gui's header").substringBefore("    if (askUpdate) {")
        assertFalse("PromptCard(" in card, "the question is inside the card")
    }
}
