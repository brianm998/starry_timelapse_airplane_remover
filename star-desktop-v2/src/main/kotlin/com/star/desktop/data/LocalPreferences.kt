package com.star.desktop.data

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.star.desktop.util.Log
import java.io.File

/**
 * Client-local UI preferences in `~/.star.userprefs.json` — the ONLY file the client serializes.
 *
 * The `recentlyOpenedSequencelist` schema (`{ "<path>": <epochSeconds> }`) is shared with the macOS
 * Swift app (`UserPreferences.swift`), so recent files are visible across both clients. Unknown
 * fields written by the Swift app are preserved on read where practical and otherwise ignored.
 */
class LocalPreferences {
    private val prefsFile = File(System.getProperty("user.home"), ".star.userprefs.json")
    private val gson = Gson()

    private val recent = linkedMapOf<String, Long>()
    private val others = linkedMapOf<String, Any?>() // unknown keys written by the Swift app — preserved on save

    /** macOS `skipRenderPromptAfterProcessing`: once set, processing starts without the render prompt. */
    @Volatile
    var skipRenderPromptAfterProcessing: Boolean = false
        private set

    init {
        load()
    }

    fun setSkipRenderPrompt(value: Boolean) {
        skipRenderPromptAfterProcessing = value
        save()
    }

    /** Recent sequence paths, most-recent first. */
    val recentFiles: List<String>
        get() = synchronized(recent) { recent.entries.sortedByDescending { it.value }.map { it.key } }

    fun addRecentFile(path: String) {
        synchronized(recent) {
            recent[path] = System.currentTimeMillis() / 1000L
            if (recent.size > 20) {
                recent.entries.sortedBy { it.value }.take(recent.size - 20).forEach { recent.remove(it.key) }
            }
        }
        save()
    }

    fun removeRecentFile(path: String) {
        synchronized(recent) { recent.remove(path) }
        save()
    }

    private fun load() {
        if (!prefsFile.exists()) return
        try {
            val type = object : TypeToken<MutableMap<String, Any?>>() {}.type
            val map: MutableMap<String, Any?> = gson.fromJson(prefsFile.readText(), type) ?: return
            @Suppress("UNCHECKED_CAST")
            val raw = map["recentlyOpenedSequencelist"] as? Map<String, Any?> ?: emptyMap()
            synchronized(recent) {
                recent.clear()
                raw.forEach { (k, v) -> recent[k] = (v as? Double)?.toLong() ?: 0L }
            }
            skipRenderPromptAfterProcessing = map["skipRenderPromptAfterProcessing"] as? Boolean ?: false
            synchronized(others) {
                others.clear()
                map.forEach { (k, v) -> if (k !in MANAGED_KEYS) others[k] = v }
            }
        } catch (e: Exception) {
            Log.w("Prefs") { "failed to read $prefsFile: ${e.message}" }
        }
    }

    private fun save() {
        try {
            val out = LinkedHashMap<String, Any?>(synchronized(others) { LinkedHashMap(others) })
            out["recentlyOpenedSequencelist"] = synchronized(recent) { LinkedHashMap(recent) }
            out["skipRenderPromptAfterProcessing"] = skipRenderPromptAfterProcessing
            prefsFile.writeText(gson.toJson(out))
        } catch (e: Exception) {
            Log.w("Prefs") { "failed to write $prefsFile: ${e.message}" }
        }
    }

    private companion object {
        val MANAGED_KEYS = setOf("recentlyOpenedSequencelist", "skipRenderPromptAfterProcessing")
    }
}
