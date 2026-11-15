package com.star.desktop.ui.initial

import com.google.gson.JsonParser
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * A recent entry opens by what it is (`gherkin/ui/vectors/recentOpenKinds.json`; the gui's `StartScreenTests` runs its own rule over the
 * same cases): a config.json resumes, a video imports, anything else opens as a sequence folder.
 */
class RecentOpenKindTest {
    private fun read(path: String) = listOf(File(path), File("../$path")).first { it.isFile }.readText()

    @Test fun theKindsAreTheVectors() {
        val cases = JsonParser.parseString(read("gherkin/ui/vectors/recentOpenKinds.json")).asJsonObject.getAsJsonArray("cases").map { it.asJsonObject }
        assertTrue(cases.size >= 15, "the vector lost cases")
        for (c in cases) {
            val path = c["path"].asString
            assertEquals(OpenKind.valueOf(c["kind"].asString.uppercase()), inferOpenKind(path), path)
        }
    }
}
