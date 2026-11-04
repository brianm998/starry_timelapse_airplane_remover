package com.star.desktop.gherkin

import com.google.gson.stream.JsonReader
import com.google.gson.stream.JsonToken
import java.io.File
import java.io.StringReader

/*
 * The path handling of the runner's "a processed copy of the sequence" step, kept apart from the Compose runner so it can be tested without stard.
 * `gherkin/ui/make-processed-fixture.sh` prints the fixture's path as bash sees it (a POSIX `/d/a/...` under Git Bash), and the cli stored that
 * path, in one spelling or another, in the fixture's json files.
 */

/**
 * The bash that runs the fixture script. Off Windows plain `bash`. On Windows a bare `bash` is found by CreateProcess in System32 first, which is WSL's
 * launcher (it prints https://aka.ms/wslstore on a runner with no distribution and exits 1), so Git Bash is looked for by its install root (`EXEPATH`,
 * which Git Bash sets, then `ProgramFiles`) and `bash` is only the fallback.
 */
internal fun bashExecutable(isWindows: Boolean, env: Map<String, String> = System.getenv(), exists: (String) -> Boolean = { File(it).isFile }): String {
    if (!isWindows) return "bash"
    val roots = listOfNotNull(env["EXEPATH"], env["ProgramFiles"]?.let { "$it\\Git" }, "C:\\Program Files\\Git")
    return roots.flatMap { listOf("$it\\bin\\bash.exe", "$it\\usr\\bin\\bash.exe") }.firstOrNull(exists) ?: "bash"
}

/** What `cygpath -m` says about [printed] (`D:/a/x`), or null when there is no cygpath or it fails. */
internal val runCygpath: (String) -> String? = { printed ->
    runCatching {
        val p = ProcessBuilder("cygpath", "-m", printed).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText().lines().firstOrNull()?.trim()
        if (p.waitFor() == 0) out else null
    }.getOrNull()
}

/**
 * The path the script printed, as a path the JVM can open. Off Windows, or for a path that is not POSIX style, it is [printed] as it is. On Windows a
 * path starting with `/` goes through [cygpath] (`cygpath -m`: drive letter, forward slashes); without cygpath `/d/rest` becomes `D:/rest`.
 */
internal fun nativeFixturePath(printed: String, isWindows: Boolean, cygpath: (String) -> String? = runCygpath): String {
    if (!isWindows || !printed.startsWith("/")) return printed
    cygpath(printed)?.takeIf { it.isNotBlank() }?.let { return it }
    val m = Regex("^/([A-Za-z])(/.*)?$").matchEntire(printed)
    return if (m != null) "${m.groupValues[1].uppercase()}:${m.groupValues[2].ifEmpty { "/" }}" else printed
}

/** Every spelling of [from] that can stand in a json file, longest first so that no spelling is clobbered by a shorter one. */
internal fun pathSpellings(from: String): List<String> {
    val slashed = from.replace('\\', '/')
    return listOf(from, slashed, slashed.replace("/", "\\\\"), slashed.replace("/", "\\")).distinct().sortedByDescending { it.length }
}

/** [json] with each spelling of [from] replaced by [to], written as json string content (forward slashes, which the JVM and the engine accept). */
internal fun rewritePaths(json: String, from: String, to: String): String {
    val replacement = to.replace('\\', '/').replace("\"", "\\\"")
    return pathSpellings(from).fold(json) { text, spelling -> text.replace(spelling, replacement) }
}

/** Whether [text] is one complete, strictly valid json value. */
private fun jsonProblem(text: String): String? = try {
    JsonReader(StringReader(text)).use { r ->
        r.skipValue()
        if (r.peek() != JsonToken.END_DOCUMENT) "trailing text after the json value" else null
    }
} catch (e: Exception) {
    e.message ?: e.javaClass.simpleName
}

/**
 * Rewrites the old path [from] to [to] in the json files under [root] that hold it, and checks that each rewritten file still parses. A file that
 * does not is a [DesktopFeatureRunner.RunnerError] naming it, rather than an engine error when the feature opens it.
 */
internal fun relocateJsonFiles(root: File, from: String, to: String) {
    val spellings = pathSpellings(from)
    root.walkTopDown().filter { it.isFile && it.extension == "json" && it.length() < 8_000_000 }.forEach { f ->
        val text = f.readText()
        if (spellings.none { it in text }) return@forEach
        val rewritten = rewritePaths(text, from, to)
        f.writeText(rewritten)
        jsonProblem(rewritten)?.let {
            throw DesktopFeatureRunner.RunnerError("${f.relativeTo(root).path} is not valid JSON after relocating the processed copy: $it")
        }
    }
}
