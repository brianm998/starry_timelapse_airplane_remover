package com.star.desktop.util

import java.awt.Desktop
import java.net.URI

/** Opens a web page in the user's browser; false when there is no browser to ask (headless) or it would not start. */
object OpenUrl {
    fun browse(url: String): Boolean {
        if (!Desktop.isDesktopSupported()) return false
        val desktop = Desktop.getDesktop()
        if (!desktop.isSupported(Desktop.Action.BROWSE)) return false
        return try {
            desktop.browse(URI.create(url))
            true
        } catch (e: Exception) {
            Log.w("OpenUrl") { "could not open $url: ${e.message}" }
            false
        }
    }
}
