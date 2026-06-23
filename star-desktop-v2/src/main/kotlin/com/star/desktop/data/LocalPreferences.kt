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

    init {
        load()
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
            val type = object : TypeToken<Map<String, Any>>() {}.type
            val map: Map<String, Any> = gson.fromJson(prefsFile.readText(), type) ?: return
            @Suppress("UNCHECKED_CAST")
            val raw = map["recentlyOpenedSequencelist"] as? Map<String, Double> ?: emptyMap()
            synchronized(recent) {
                recent.clear()
                raw.forEach { (k, v) -> recent[k] = v.toLong() }
            }
        } catch (e: Exception) {
            Log.w("Prefs") { "failed to read $prefsFile: ${e.message}" }
        }
    }

    private fun save() {
        try {
            val snapshot = synchronized(recent) { LinkedHashMap(recent) }
            prefsFile.writeText(gson.toJson(mapOf("recentlyOpenedSequencelist" to snapshot)))
        } catch (e: Exception) {
            Log.w("Prefs") { "failed to write $prefsFile: ${e.message}" }
        }
    }
}
