package com.star.desktop.domain

import com.google.gson.JsonParser
import com.star.proto.RemoveReason
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Layer 0 of the parity plan (§6.2.4), E1 and E2: what a click on an outlier group does is `gherkin/ui/vectors/clickRules.json`, which the
 * gui's `OutlierGroupView` is held to as well (`ClickRuleTests`). The desktop's own tests of the rules (`ClickRulesTest`) say why; this says they
 * are the same ones.
 */
class ClickRulesVectorTest {
    private val doc = JsonParser.parseString(
        listOf(File("../gherkin/ui/vectors/clickRules.json"), File("gherkin/ui/vectors/clickRules.json")).first { it.isFile }.readText(),
    ).asJsonObject

    private fun reason(name: String) = when (name) {
        "undecided" -> RemoveReason.RR_UNDECIDED
        "classifierRemove" -> RemoveReason.RR_CLASSIFIER_REMOVE
        "classifierKeep" -> RemoveReason.RR_CLASSIFIER_KEEP
        "userRemove" -> RemoveReason.RR_USER_REMOVE
        "userKeep" -> RemoveReason.RR_USER_KEEP
        else -> error(name)
    }

    private fun tool(name: String) = when (name) {
        "remove" -> ToolType.REMOVE
        "keep" -> ToolType.KEEP
        "razor" -> ToolType.RAZOR
        "shovel" -> ToolType.SHOVEL
        "trash" -> ToolType.TRASH
        "removeFromTrash" -> ToolType.REMOVE_FROM_TRASH
        "multi" -> ToolType.MULTI
        "information" -> ToolType.INFORMATION
        "none" -> ToolType.NONE
        else -> error(name)
    }

    @Test fun aClickLeavesTheOppositeDecision() {
        val cases = doc.getAsJsonArray("toggle")
        assertTrue(cases.size() >= 5)
        for (element in cases) {
            val c = element.asJsonObject
            assertEquals(reason(c["after"].asString), OutlierDecisions.toggled(reason(c["decision"].asString)), c.toString())
        }
    }

    @Test fun aClickOnAGroupDoesWhatTheVectorSays() {
        val cases = doc.getAsJsonArray("groupClick")
        assertEquals(ToolType.entries.size * 4, cases.size(), "every tool, with the switch on and off, on a decided and an undecided group")
        for (element in cases) {
            val c = element.asJsonObject
            val expected = if (c["expected"].asString == "multiChoiceSheet") ClickRules.GroupClick.OPEN_MULTI_CHOICE else ClickRules.GroupClick.APPLY_TOOL
            assertEquals(expected, ClickRules.groupClick(tool(c["tool"].asString), c["multiChoice"].asBoolean, c["decided"].asBoolean), c.toString())
        }
    }
}
