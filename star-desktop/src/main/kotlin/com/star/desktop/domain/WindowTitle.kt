package com.star.desktop.domain

import com.star.desktop.i18n.localized

/** What the main window's title bar says (macOS `ImageSequenceViewModel.windowTitle`): "Star - <folder>" with a sequence open, "Star" otherwise. */
object WindowTitle {
    /** The product's name, which is not translated (the catalogue's `ui.star` is the word for the thing in the sky, in lower case). */
    const val APP_NAME = "Star"

    /** The title for a window holding the sequence in [folderName], or none if nothing is open. */
    fun of(folderName: String?): String = if (folderName.isNullOrBlank()) APP_NAME else localized("ui.window_title", folderName)
}
