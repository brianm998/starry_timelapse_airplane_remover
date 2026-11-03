package com.star.desktop.gherkin

import com.google.gson.JsonParser
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** The path handling of the runner's "a processed copy of the sequence" step (`ProcessedCopyPaths.kt`), which needs no stard and no processed fixture.
 * The features that start from a processed copy (uiOutlierClicks, uiMultiChoiceSheet, ...) prove it end to end, on the Windows `ui` leg among others. */
class ProcessedCopyPathsTest {
    @Test fun aGitBashPathBecomesAWindowsPath() {
        // cygpath answers: its answer is used.
        assertEquals("D:/a/x/y", nativeFixturePath("/d/a/x/y", isWindows = true) { assertEquals("/d/a/x/y", it); "D:/a/x/y" })
        // No cygpath: the drive is read from the path.
        assertEquals("D:/a/x/y", nativeFixturePath("/d/a/x/y", isWindows = true) { null })
        assertEquals("C:/", nativeFixturePath("/c", isWindows = true) { null })
        // Off Windows, and for paths that are not POSIX style, nothing changes (cygpath is not even asked).
        assertEquals("/d/a/x/y", nativeFixturePath("/d/a/x/y", isWindows = false) { error("asked") })
        assertEquals("C:\\a\\b", nativeFixturePath("C:\\a\\b", isWindows = true) { error("asked") })
    }

    @Test fun windowsRunsGitBashNotTheWslLauncher() {
        val gitBash = "C:\\Program Files\\Git\\bin\\bash.exe"
        assertEquals(gitBash, bashExecutable(true, mapOf("EXEPATH" to "C:\\Program Files\\Git")) { it == gitBash })
        assertEquals(gitBash, bashExecutable(true, emptyMap()) { it == gitBash })
        assertEquals("bash", bashExecutable(true, emptyMap()) { false })
        assertEquals("bash", bashExecutable(false, emptyMap()) { error("asked") })
    }

    @Test fun rewrittenJsonStaysValidAndPointsAtTheCopy() {
        val copy = "C:\\Users\\runner\\AppData\\Local\\Temp\\processed"
        val from = "D:/a/star/.test-data/ui-processed/seq"
        val root = Files.createTempDirectory("processedCopy").toFile()
        try {
            val json = """{"asis":"$from/input","escaped":"D:\\a\\star\\.test-data\\ui-processed\\seq\\input","list":["$from","${from}/x"],"other":"keep"}"""
            File(root, "sub").mkdirs()
            File(root, "sub/config.json").writeText(json)
            File(root, "untouched.json").writeText("""{"other":"keep"}""")
            File(root, "notes.txt").writeText(from)
            relocateJsonFiles(root, from, copy)
            val parsed = JsonParser.parseString(File(root, "sub/config.json").readText()).asJsonObject
            assertEquals("C:/Users/runner/AppData/Local/Temp/processed/input", parsed["asis"].asString)
            // The path's own part is the copy's; what the cli appended after it keeps its backslashes, which Windows accepts mixed with slashes.
            assertEquals("C:/Users/runner/AppData/Local/Temp/processed/input", parsed["escaped"].asString.replace('\\', '/'))
            assertEquals(listOf("C:/Users/runner/AppData/Local/Temp/processed", "C:/Users/runner/AppData/Local/Temp/processed/x"), parsed["list"].asJsonArray.map { it.asString })
            assertEquals("keep", parsed["other"].asString)
            assertEquals("""{"other":"keep"}""", File(root, "untouched.json").readText())
            assertEquals(from, File(root, "notes.txt").readText())
            // The old path, spelled as the cli might have: raw Windows form too.
            assertEquals("""{"p":"C:/x"}""", rewritePaths("""{"p":"D:\\a\\b"}""", "D:\\a\\b", "C:\\x"))
            assertTrue("D:" !in File(root, "sub/config.json").readText())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun aBrokenRewriteIsReportedByTheRunner() {
        val root = Files.createTempDirectory("processedCopyBroken").toFile()
        try {
            File(root, "broken.json").writeText("""{"path":"/old/place","n":""")
            val e = assertFailsWith<DesktopFeatureRunner.RunnerError> { relocateJsonFiles(root, "/old/place", "/new/place") }
            assertTrue("broken.json" in (e.message ?: ""), e.message)
        } finally {
            root.deleteRecursively()
        }
    }
}
