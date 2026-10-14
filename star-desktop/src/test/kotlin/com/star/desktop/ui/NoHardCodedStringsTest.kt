package com.star.desktop.ui

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Nothing the screens say is written into their code: every word on screen is a catalogue key looked up with `localized(...)`, so that it
 * follows the language (H6). This reads the sources under `ui/` and fails on a string literal that reads as something shown to a person:
 *
 *  - one handed straight to a call that puts text on screen (`Text(`, `HoverTip(`, `contentDescription =` …), or
 *  - one that is prose anywhere else in `ui/` (it starts with a capital, or has a word, a space and another word), since a label held in a
 *    value that is drawn later is no different.
 *
 * Keys, ids, file names and the like are not prose and pass. A literal that has to stay (a brand, a technical id) goes in [ALLOWED] with the reason.
 */
class NoHardCodedStringsTest {
    /** "file:literal" → why it may stay. */
    private val ALLOWED: Map<String, String> = mapOf(
        "ProcessingSettingsDialog.kt:GPU" to "the acronym, the stand-in for a device name the engine did not give",
    )

    /** Lines of ProcessingSettingsDialog.kt whose literals are field ids (the key of the edit maps, never drawn): what the row says is its labelKey. */
    private val FIELD_ID_LINE = Regex("""^\s*((Int|Bool|Double)Field\(|"[^"]*" to listOf\(|(private|internal) (const )?va[lr] [A-Za-z_]+(: [^=]+)? = )""")

    private val sink = Regex(
        """(?:\bText\(\s*(?:text\s*=\s*)?|\bHoverTip\(\s*|\bChip\(\s*|\bSectionTitle\(\s*|\bPrimaryButton\(\s*|\bSecondaryButton\(\s*|""" +
            """\bGlyphButton\(\s*"[^"]*"\s*,\s*|contentDescription\s*=\s*|\btitle\s*=\s*)"((?:[^"\\]|\\.)*)"""",
    )
    private val literal = Regex(""""((?:[^"\\\n]|\\.)*)"""")

    /** Units written after a number: the same in every language the app is shown in. */
    private val UNITS = setOf("px", "MB", "GB", "")

    private fun uiDir(): File {
        val relative = "src/main/kotlin/com/star/desktop/ui"
        return listOf(File(relative), File("star-desktop/$relative")).first { it.isDirectory }
    }

    /** The source with comments blanked out (so a quoted word in a doc comment is not a literal), keeping every line where it was. */
    private fun withoutComments(src: String): String {
        val out = StringBuilder()
        var i = 0
        while (i < src.length) {
            val c = src[i]
            when {
                src.startsWith("\"\"\"", i) -> {
                    val end = src.indexOf("\"\"\"", i + 3).let { if (it < 0) src.length else it + 3 }
                    out.append(src, i, end); i = end
                }
                c == '"' || c == '\'' -> {
                    var j = i + 1
                    while (j < src.length && src[j] != c && src[j] != '\n') { if (src[j] == '\\') j++; j++ }
                    val end = minOf(j + 1, src.length)
                    out.append(src, i, end); i = end
                }
                src.startsWith("//", i) -> {
                    val end = src.indexOf('\n', i).let { if (it < 0) src.length else it }
                    out.append(" ".repeat(end - i)); i = end
                }
                src.startsWith("/*", i) -> {
                    val end = src.indexOf("*/", i + 2).let { if (it < 0) src.length else it + 2 }
                    out.append(src.substring(i, end).replace(Regex("[^\n]"), " ")); i = end
                }
                else -> { out.append(c); i++ }
            }
        }
        return out.toString()
    }

    /**
     * The source with its `Log.d("Tag") { "message" }` calls blanked out: a log line is for whoever reads the log, in English, and is not shown to
     * the user (what is shown comes from `localized`).
     */
    private fun withoutLogCalls(src: String): String {
        val out = StringBuilder(src)
        fun skipString(from: Int, quote: Char): Int {
            var j = from + 1
            while (j < src.length && src[j] != quote && src[j] != '\n') { if (src[j] == '\\') j++; j++ }
            return minOf(j + 1, src.length)
        }
        fun balanced(from: Int, open: Char, close: Char): Int {
            var depth = 0
            var j = from
            while (j < src.length) {
                when (src[j]) {
                    '"', '\'' -> { j = skipString(j, src[j]); continue }
                    open -> depth++
                    close -> { depth--; if (depth == 0) return j + 1 }
                }
                j++
            }
            return src.length
        }
        for (m in Regex("""\bLog\.[diwe]\(""").findAll(src)) {
            var end = balanced(m.range.last, '(', ')')
            var k = end
            while (k < src.length && (src[k] == ' ' || src[k] == '\n')) k++
            if (k < src.length && src[k] == '{') end = balanced(k, '{', '}')
            for (x in m.range.first until end) if (out[x] != '\n') out[x] = ' '
        }
        return out.toString()
    }

    /** What is left of a literal once the values spliced into it (`$x`, `${...}`) are taken out: the words that are written down. */
    private fun words(literal: String): String = literal.replace(Regex("""\$\{[^}]*}"""), "").replace(Regex("""\$[A-Za-z_][A-Za-z0-9_]*"""), "")

    private fun looksLikeProse(text: String): Boolean {
        val w = words(text)
        if (!Regex("[A-Za-z]{2}").containsMatchIn(w)) return false
        // a constant's name, as in @Suppress("UNCHECKED_CAST"): capitals and underscores only
        if (Regex("[A-Z_0-9]+").matches(w)) return false
        return Regex("^[A-Z][a-z]").containsMatchIn(w) || Regex("[A-Za-z]\\s+[A-Za-z]").containsMatchIn(w)
    }

    private fun allowed(file: String, text: String) = "$file:$text" in ALLOWED

    @Test fun noScreenWritesItsWordsInCode() {
        val problems = ArrayList<String>()
        for (file in uiDir().walkTopDown().filter { it.isFile && it.extension == "kt" }) {
            val lines = withoutLogCalls(withoutComments(file.readText())).split('\n')
            val source = lines.joinToString("\n")
            val flaggedAt = HashSet<Pair<Int, String>>()
            fun lineOf(offset: Int) = source.substring(0, offset).count { it == '\n' } + 1

            for (m in sink.findAll(source)) {
                val text = m.groupValues[1]
                val line = lineOf(m.range.first)
                // "${localized("ui.x")}: …" holds a literal of its own, which the match ends at; what is drawn is looked up
                if (text.startsWith("\${localized(")) continue
                if (words(text).filter { it.isLetter() } in UNITS) continue
                if (Regex("[A-Za-z]{2}").containsMatchIn(words(text)) && !allowed(file.name, text) && flaggedAt.add(line to text)) {
                    problems += "${file.name}:$line: \"$text\" is given to a call that draws text"
                }
            }
            for ((index, line) in lines.withIndex()) {
                if (file.name == "ProcessingSettingsDialog.kt" && FIELD_ID_LINE.containsMatchIn(line)) continue
                if (line.trimStart().startsWith("@file:") || line.trimStart().startsWith("import ")) continue
                for (m in literal.findAll(line)) {
                    val text = m.groupValues[1]
                    if (looksLikeProse(text) && !allowed(file.name, text) && flaggedAt.add(index + 1 to text)) {
                        problems += "${file.name}:${index + 1}: \"$text\" reads as something shown to a person"
                    }
                }
            }
        }
        assertTrue(problems.isEmpty(), "Hard-coded text in ui/ (use localized(\"ui.…\") and add the key to every catalogue):\n" + problems.joinToString("\n"))
    }

    /** The check must be able to fail: these are the shapes it exists to catch. */
    @Test fun theCheckNoticesWhatItIsFor() {
        assertTrue(looksLikeProse("Paint Horizon"))
        assertTrue(looksLikeProse("Processed"))
        assertTrue(looksLikeProse("Frame $1 of the video".replace("$1", "\$index")))
        assertTrue(looksLikeProse("engine stopped"))
        assertTrue(!looksLikeProse("ui.close_session"))
        assertTrue(!looksLikeProse("\$count"))
        assertTrue(!looksLikeProse("UNCHECKED_CAST"))
        assertTrue(!looksLikeProse("videos/\$INTRO_VIDEO_NAME"))
        assertTrue(!looksLikeProse("−"))
        val text = sink.find("""Text("Hello there", color = X)""")
        assertTrue(text != null && text.groupValues[1] == "Hello there")
        assertTrue(sink.find("""HoverTip("tip") { }""") != null)
        assertTrue(sink.find("""Text(localized("ui.x"))""") == null)
    }
}
